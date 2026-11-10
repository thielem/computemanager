import Darwin
import Foundation

// MARK: - Unix domain socket + NDJSON transport
//
// Blocking POSIX I/O on dedicated threads (never on the Swift cooperative pool).
// - Server: one accept thread, one thread per connection. Typed handlers are `async`; each
//   request is bridged onto its connection thread, so a slow handler (long-poll) only blocks
//   its own connection.
// - Client: synchronous request/response (fits CLIs; the app wraps calls off the main actor).
//   `call` enforces one overall deadline across all its syscalls.
// - Server hardening: probe before bind (`alreadyRunning` vs stale file), max
//   `Defaults.maxConnections` connections, send timeout on accepted sockets, accept loop
//   survives transient errors, unauthorized peers are answered once and disconnected,
//   `onDisconnect` hook. No idle read timeout: subscribers are idle by design.
// All sockets are close-on-exec and SO_NOSIGPIPE.

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)
    /// Peer closed the connection.
    case closed
    /// Read/write timed out (or the overall deadline of a call passed).
    case timeout
    case lineTooLong
    /// `start()`: another live server already listens on this path.
    case alreadyRunning(String)

    public var description: String {
        switch self {
        case .pathTooLong(let p): "socket path too long: \(p)"
        case .syscall(let name, let e): "\(name): \(String(cString: strerror(e)))"
        case .closed: "connection closed"
        case .timeout: "timed out"
        case .lineTooLong: "line exceeds \(Defaults.maxLineBytes) bytes"
        case .alreadyRunning(let p): "another server is already listening on \(p)"
        }
    }
}

/// Credentials of the connected peer (from `getpeereid` / `LOCAL_PEERPID`).
public struct PeerCredentials: Sendable, Equatable {
    public var uid: uid_t
    public var gid: gid_t
    public var pid: pid_t?
}

/// Opaque per-process identity of one connection (for `RequestContext` / `onDisconnect`).
public struct ConnectionID: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt64
    public var description: String { "conn#\(raw)" }

    private final class Counter: @unchecked Sendable {  // guarded by `lock`
        let lock = NSLock()
        var next: UInt64 = 0
    }
    private static let counter = Counter()

    static func make() -> ConnectionID {
        counter.lock.lock()
        defer { counter.lock.unlock() }
        counter.next += 1
        return ConnectionID(raw: counter.next)
    }
}

/// `timeval` for a socket timeout. nil → 0 (block forever). A non-positive value is invalid,
/// not "infinite": it maps to 1 µs, i.e. an immediate timeout.
private func timevalFor(_ t: TimeInterval?) -> timeval {
    guard let t else { return timeval(tv_sec: 0, tv_usec: 0) }
    let us = max(1, Int64((t * 1_000_000).rounded(.up)))
    return timeval(tv_sec: Int(us / 1_000_000), tv_usec: Int32(us % 1_000_000))
}

/// One connected socket that reads and writes NDJSON lines. Thread-safe for one reader plus
/// concurrent writers.
public final class LineConnection: @unchecked Sendable {
    public let fd: Int32
    public let id = ConnectionID.make()
    private var buffer = Data()       // reader thread only
    private var scanned = 0           // bytes of `buffer` already searched for a newline
    private var recvTimeout: TimeInterval?
    private var sendTimeout: TimeInterval?
    private let writeLock = NSLock()
    private let closeLock = NSLock()
    private var isClosed = false

    init(fd: Int32) { self.fd = fd }

    deinit { close() }

    public var peer: PeerCredentials? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let ok = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0
        return PeerCredentials(uid: uid, gid: gid, pid: ok ? pid : nil)
    }

    /// Per-syscall timeout for reads AND writes (nil = block forever; ≤ 0 = immediate timeout).
    public func setReadTimeout(_ t: TimeInterval?) {
        recvTimeout = t
        sendTimeout = t
        apply(SO_RCVTIMEO, t)
        apply(SO_SNDTIMEO, t)
    }

    /// Per-syscall timeout for writes only.
    public func setSendTimeout(_ t: TimeInterval?) {
        sendTimeout = t
        apply(SO_SNDTIMEO, t)
    }

    private func apply(_ opt: Int32, _ t: TimeInterval?) {
        var tv = timevalFor(t)
        setsockopt(fd, SOL_SOCKET, opt, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Before a syscall under an overall `deadline`: set the socket timeout to the time left,
    /// or throw `.timeout` if none is left.
    private func arm(_ opt: Int32, _ deadline: Date?) throws {
        guard let deadline else { return }
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else { throw SocketError.timeout }
        apply(opt, left)
    }

    /// Next line without the trailing newline; nil on clean EOF. With `deadline`, the whole
    /// read (all syscalls) must finish before it.
    public func readLine(maxBytes: Int = Defaults.maxLineBytes, deadline: Date? = nil) throws -> Data? {
        defer { if deadline != nil { apply(SO_RCVTIMEO, recvTimeout) } }
        while true {
            if let nl = buffer[(buffer.startIndex + scanned)...].firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                scanned = 0
                guard line.count <= maxBytes else { throw SocketError.lineTooLong }
                return line
            }
            scanned = buffer.count
            guard buffer.count <= maxBytes else { throw SocketError.lineTooLong }
            try arm(SO_RCVTIMEO, deadline)
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
            } else if n == 0 {
                if buffer.isEmpty { return nil }
                throw SocketError.closed
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
                throw SocketError.syscall("read", errno)
            }
        }
    }

    /// Write one line (newline appended). With `deadline`, all write syscalls must finish
    /// before it.
    public func writeLine(_ line: Data, deadline: Date? = nil) throws {
        var out = line
        out.append(UInt8(ascii: "\n"))
        writeLock.lock()
        defer { writeLock.unlock() }
        defer { if deadline != nil { apply(SO_SNDTIMEO, sendTimeout) } }
        try out.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var off = 0
            while off < raw.count {
                try arm(SO_SNDTIMEO, deadline)
                let n = Darwin.write(fd, base + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw SocketError.timeout }
                    if errno == EPIPE { throw SocketError.closed }
                    throw SocketError.syscall("write", errno)
                }
                off += n
            }
        }
    }

    /// Wake a blocked reader/writer without releasing the fd. No-op once closed (the fd
    /// number may already belong to someone else).
    func shutdown() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(fd)
    }
}

enum UnixSocket {
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &addr) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func connect(path: String, timeout: TimeInterval?) throws -> LineConnection {
        let fd = try makeSocket()
        var rc: Int32
        repeat {
            rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
        } while rc != 0 && errno == EINTR
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError.syscall("connect", e)
        }
        let conn = LineConnection(fd: fd)
        conn.setReadTimeout(timeout)
        return conn
    }
}

/// Raw line server: accepts connections and hands each to `onConnection` on its own thread.
/// At most `maxConnections` at once; excess connections are closed immediately. Accepted
/// sockets get a send timeout (`Defaults.serverSendTimeout`) so a peer that stops reading
/// cannot block a writer forever.
public final class UnixSocketServer: @unchecked Sendable {  // mutable state guarded by `lock`
    public let path: String
    public let maxConnections: Int
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var connections: [ConnectionID: LineConnection] = [:]
    private var stopped = false

    public init(path: String, maxConnections: Int = Defaults.maxConnections) {
        self.path = path
        self.maxConnections = maxConnections
    }

    /// Bind, chmod to `mode`, listen, start accepting. Creates the parent directory if missing.
    /// If a live server answers on `path` → throws `alreadyRunning`; a stale socket file
    /// (connect gives ECONNREFUSED) is replaced.
    public func start(mode: mode_t = 0o600,
                      onConnection: @escaping @Sendable (LineConnection) -> Void) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            let probe = try UnixSocket.connect(path: path, timeout: 1)
            probe.close()
            throw SocketError.alreadyRunning(path)
        } catch SocketError.syscall("connect", let e) where e == ECONNREFUSED || e == ENOENT {
            if e == ECONNREFUSED { unlink(path) }
        }
        let fd = try UnixSocket.makeSocket()
        let rc = try UnixSocket.withAddress(path) { Darwin.bind(fd, $0, $1) }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError.syscall("bind", e)
        }
        chmod(path, mode)
        guard listen(fd, 64) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError.syscall("listen", e)
        }
        lock.lock()
        listenFD = fd
        lock.unlock()
        let t = Thread { [self] in acceptLoop(fd: fd, onConnection: onConnection) }
        t.name = "UnixSocketServer.accept"
        t.start()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(fd: Int32, onConnection: @escaping @Sendable (LineConnection) -> Void) {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                let e = errno
                if isStopped { return }  // listen socket closed by stop()
                if e != EINTR {
                    // Transient (EMFILE, ENFILE, ECONNABORTED, …): back off, keep serving.
                    Thread.sleep(forTimeInterval: Defaults.acceptRetryDelay)
                }
                continue
            }
            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let conn = LineConnection(fd: cfd)
            conn.setSendTimeout(Defaults.serverSendTimeout)
            lock.lock()
            if stopped {
                lock.unlock()
                conn.close()
                return
            }
            guard connections.count < maxConnections else {
                lock.unlock()
                conn.close()
                continue
            }
            connections[conn.id] = conn
            lock.unlock()
            let t = Thread { [self] in
                onConnection(conn)
                lock.lock()
                connections[conn.id] = nil
                lock.unlock()
                conn.close()
            }
            t.name = "UnixSocketServer.conn"
            t.start()
        }
    }

    /// Number of open connections (for tests/diagnostics).
    public var connectionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    /// Stop accepting, wake all connections (their threads close them), remove the socket file.
    public func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let conns = Array(connections.values)
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for c in conns { c.shutdown() }
        if !wasStopped, fd >= 0 { unlink(path) }
    }
}

// MARK: - Typed layer

/// Context passed to typed handlers.
public struct RequestContext<Reply: OpMessage>: Sendable {
    public let peer: PeerCredentials?
    public let requestId: String
    /// Identity of the connection this request came on (matches `onDisconnect`).
    public let connectionId: ConnectionID
    let connection: LineConnection

    /// Push an extra reply on this connection with the request's id (for `subscribe` streams).
    /// Throws when the client has gone away or stopped reading (send timeout
    /// `Defaults.serverSendTimeout` → `.timeout`); stop streaming then.
    public func push(_ reply: Reply) throws {
        try connection.writeLine(WireCoding.line(Response<Reply>(id: requestId, reply)))
    }
}

/// NDJSON request/response server over a Unix socket.
public final class MessageServer<Req: OpMessage, Reply: OpMessage>: @unchecked Sendable {
    public typealias Handler = @Sendable (Req, RequestContext<Reply>) async -> Result<Reply, WireError>
    /// Return false to answer the first request with `unauthorized` and close the connection.
    public typealias Authorizer = @Sendable (PeerCredentials?) -> Bool
    /// Called once on the connection's thread after it ended (EOF, error, crash of the peer,
    /// unauthorized, or `stop()`), before the fd is closed.
    public typealias DisconnectHandler = @Sendable (ConnectionID, PeerCredentials?) -> Void

    private let server: UnixSocketServer
    private let handler: Handler
    private let authorize: Authorizer
    private let onDisconnect: DisconnectHandler?

    public var path: String { server.path }
    public var connectionCount: Int { server.connectionCount }

    public init(path: String, maxConnections: Int = Defaults.maxConnections,
                authorize: @escaping Authorizer = { _ in true },
                onDisconnect: DisconnectHandler? = nil,
                handler: @escaping Handler) {
        self.server = UnixSocketServer(path: path, maxConnections: maxConnections)
        self.handler = handler
        self.authorize = authorize
        self.onDisconnect = onDisconnect
    }

    /// Throws `SocketError.alreadyRunning` if another live server listens on `path`.
    public func start(mode: mode_t = 0o600) throws {
        let handler = handler, authorize = authorize, onDisconnect = onDisconnect
        try server.start(mode: mode) { conn in
            let peer = conn.peer
            Self.serve(conn, peer: peer, handler: handler, authorize: authorize)
            onDisconnect?(conn.id, peer)
        }
    }

    public func stop() { server.stop() }

    private static func serve(_ conn: LineConnection, peer: PeerCredentials?,
                              handler: @escaping Handler, authorize: Authorizer) {
        let allowed = authorize(peer)
        while true {
            let line: Data
            do {
                guard let l = try conn.readLine() else { return }
                line = l
            } catch {
                if case SocketError.lineTooLong = error {
                    _ = try? conn.writeLine(WireCoding.line(
                        Response<Reply>(id: "", op: "", error: WireError(.badRequest, "line too long"))))
                }
                return
            }
            let response: Response<Reply>
            let probe = try? WireCoding.decode(EnvelopeProbe.self, line: line)
            let id = probe?.id ?? "", op = probe?.op ?? ""
            guard allowed else {
                _ = try? conn.writeLine(WireCoding.line(
                    Response<Reply>(id: id, op: op, error: WireError(.unauthorized, "peer not allowed"))))
                return
            }
            do {
                let req = try WireCoding.decode(Request<Req>.self, line: line)
                let ctx = RequestContext<Reply>(peer: peer, requestId: req.id,
                                                connectionId: conn.id, connection: conn)
                switch runBlocking({ await handler(req.message, ctx) }) {
                case .success(let r): response = Response(id: req.id, r)
                case .failure(let e): response = Response(id: req.id, op: op, error: e)
                }
            } catch let e as WireError {
                response = Response(id: id, op: op, error: e)
            } catch {
                response = Response(id: id, op: op, error: WireError(.badRequest, "\(error)"))
            }
            do {
                try conn.writeLine(WireCoding.line(response))
            } catch {
                return
            }
        }
    }
}

/// Minimal decode of `id`/`op` for error replies to malformed requests.
private struct EnvelopeProbe: Decodable {
    var id: String?
    var op: String?
}

/// Run an async closure to completion from a dedicated (non-cooperative) thread.
private final class BlockingBox<T>: @unchecked Sendable { var value: T? }

private func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = BlockingBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = await body()
        sem.signal()
    }
    sem.wait()
    return box.value!
}

/// Synchronous NDJSON client. One connection; requests are sequential (not thread-safe:
/// use one client per thread, e.g. separate connections for `subscribe` and requests).
public final class MessageClient<Req: OpMessage, Reply: OpMessage>: @unchecked Sendable {
    private let conn: LineConnection
    private var timeout: TimeInterval?

    /// Connect to `path`. `timeout` (nil = none) is the overall deadline of each `call`, and
    /// the per-syscall timeout of `send`/`next`. A value ≤ 0 is invalid and times out at once.
    public init(path: String, timeout: TimeInterval? = Defaults.clientTimeout) throws {
        conn = try UnixSocket.connect(path: path, timeout: timeout)
        self.timeout = timeout
    }

    public func setTimeout(_ t: TimeInterval?) {
        timeout = t
        conn.setReadTimeout(t)
    }

    /// Send a request and wait for its reply, all within `timeout` in total (across every
    /// read/write; `cgate hook` relies on this to fail open within 0.5 s). Failure responses
    /// throw `WireError`; transport problems throw `SocketError`.
    public func call(_ message: Req) throws -> Reply {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let req = Request(message)
        try conn.writeLine(WireCoding.line(req), deadline: deadline)
        while true {
            let r = try next(deadline: deadline)
            guard r.id == req.id else { continue }
            return try r.result.get()
        }
    }

    /// Send without waiting; returns the request id. Use `next()` to read (streams).
    @discardableResult
    public func send(_ message: Req) throws -> String {
        let req = Request(message)
        try conn.writeLine(WireCoding.line(req))
        return req.id
    }

    /// Read the next response envelope.
    public func next() throws -> Response<Reply> { try next(deadline: nil) }

    private func next(deadline: Date?) throws -> Response<Reply> {
        guard let line = try conn.readLine(deadline: deadline) else { throw SocketError.closed }
        return try WireCoding.decode(Response<Reply>.self, line: line)
    }

    public func close() { conn.close() }
}

public typealias GateClient = MessageClient<GateRequest, GateReply>
public typealias GateServer = MessageServer<GateRequest, GateReply>
public typealias FanClient = MessageClient<FanRequest, FanReply>
public typealias FanServer = MessageServer<FanRequest, FanReply>
