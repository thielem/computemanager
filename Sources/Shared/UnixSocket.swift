import Darwin
import Foundation

// MARK: - Unix domain socket + NDJSON transport
//
// Blocking POSIX I/O on dedicated threads (never on the Swift cooperative pool).
// - Server: one accept thread, one thread per connection. Typed handlers are `async`; each
//   request is bridged onto its connection thread, so a slow handler (long-poll) only blocks
//   its own connection.
// - Client: synchronous request/response (fits CLIs; the app wraps calls off the main actor).
// All sockets are close-on-exec and SO_NOSIGPIPE.

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case pathTooLong(String)
    case syscall(String, Int32)
    /// Peer closed the connection.
    case closed
    /// Read/write timed out.
    case timeout
    case lineTooLong

    public var description: String {
        switch self {
        case .pathTooLong(let p): "socket path too long: \(p)"
        case .syscall(let name, let e): "\(name): \(String(cString: strerror(e)))"
        case .closed: "connection closed"
        case .timeout: "timed out"
        case .lineTooLong: "line exceeds \(Defaults.maxLineBytes) bytes"
        }
    }
}

/// Credentials of the connected peer (from `getpeereid` / `LOCAL_PEERPID`).
public struct PeerCredentials: Sendable, Equatable {
    public var uid: uid_t
    public var gid: gid_t
    public var pid: pid_t?
}

/// One connected socket that reads and writes NDJSON lines. Thread-safe for one reader plus
/// concurrent writers.
public final class LineConnection: @unchecked Sendable {
    public let fd: Int32
    private var buffer = Data()
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

    /// Read timeout for subsequent reads (nil = block forever).
    public func setReadTimeout(_ t: TimeInterval?) {
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        if let t {
            tv.tv_sec = Int(t)
            tv.tv_usec = Int32((t - Double(Int(t))) * 1_000_000)
        }
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Next line without the trailing newline; nil on clean EOF.
    public func readLine(maxBytes: Int = Defaults.maxLineBytes) throws -> Data? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard line.count <= maxBytes else { throw SocketError.lineTooLong }
                return Data(line)
            }
            guard buffer.count <= maxBytes else { throw SocketError.lineTooLong }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, 4096) }
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

    /// Write one line (newline appended).
    public func writeLine(_ line: Data) throws {
        var out = line
        out.append(UInt8(ascii: "\n"))
        writeLock.lock()
        defer { writeLock.unlock() }
        try out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
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
        let rc = try withAddress(path) { Darwin.connect(fd, $0, $1) }
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
public final class UnixSocketServer: @unchecked Sendable {
    public let path: String
    private var listenFD: Int32 = -1
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: LineConnection] = [:]
    private var stopped = false

    public init(path: String) { self.path = path }

    /// Bind, chmod to `mode`, listen, start accepting. Removes a stale socket file first and
    /// creates the parent directory if missing.
    public func start(mode: mode_t = 0o600,
                      onConnection: @escaping @Sendable (LineConnection) -> Void) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        unlink(path)
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
        listenFD = fd
        let t = Thread { [self] in acceptLoop(fd: fd, onConnection: onConnection) }
        t.name = "UnixSocketServer.accept"
        t.start()
    }

    private func acceptLoop(fd: Int32, onConnection: @escaping @Sendable (LineConnection) -> Void) {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 {
                if errno == EINTR { continue }
                return  // listen socket closed by stop()
            }
            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let conn = LineConnection(fd: cfd)
            lock.lock()
            if stopped {
                lock.unlock()
                conn.close()
                return
            }
            connections[ObjectIdentifier(conn)] = conn
            lock.unlock()
            let t = Thread { [self] in
                onConnection(conn)
                conn.close()
                lock.lock()
                connections[ObjectIdentifier(conn)] = nil
                lock.unlock()
            }
            t.name = "UnixSocketServer.conn"
            t.start()
        }
    }

    /// Stop accepting, close all connections, remove the socket file.
    public func stop() {
        lock.lock()
        stopped = true
        let conns = Array(connections.values)
        connections.removeAll()
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        for c in conns {
            shutdown(c.fd, SHUT_RDWR)
        }
        unlink(path)
    }
}

// MARK: - Typed layer

/// Context passed to typed handlers.
public struct RequestContext<Reply: OpMessage>: Sendable {
    public let peer: PeerCredentials?
    public let requestId: String
    let connection: LineConnection

    /// Push an extra reply on this connection with the request's id (for `subscribe` streams).
    /// Throws when the client has gone away; stop streaming then.
    public func push(_ reply: Reply) throws {
        try connection.writeLine(WireCoding.line(Response<Reply>(id: requestId, reply)))
    }
}

/// NDJSON request/response server over a Unix socket.
public final class MessageServer<Req: OpMessage, Reply: OpMessage>: @unchecked Sendable {
    public typealias Handler = @Sendable (Req, RequestContext<Reply>) async -> Result<Reply, WireError>
    /// Return false to answer every request on the connection with `unauthorized`.
    public typealias Authorizer = @Sendable (PeerCredentials?) -> Bool

    private let server: UnixSocketServer
    private let handler: Handler
    private let authorize: Authorizer

    public var path: String { server.path }

    public init(path: String, authorize: @escaping Authorizer = { _ in true },
                handler: @escaping Handler) {
        self.server = UnixSocketServer(path: path)
        self.handler = handler
        self.authorize = authorize
    }

    public func start(mode: mode_t = 0o600) throws {
        let handler = handler, authorize = authorize
        try server.start(mode: mode) { conn in
            Self.serve(conn, handler: handler, authorize: authorize)
        }
    }

    public func stop() { server.stop() }

    private static func serve(_ conn: LineConnection, handler: @escaping Handler, authorize: Authorizer) {
        let peer = conn.peer
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
            do {
                let req = try WireCoding.decode(Request<Req>.self, line: line)
                if !allowed {
                    response = Response(id: id, op: op, error: WireError(.unauthorized, "peer not allowed"))
                } else {
                    let ctx = RequestContext<Reply>(peer: peer, requestId: req.id, connection: conn)
                    switch runBlocking({ await handler(req.message, ctx) }) {
                    case .success(let r): response = Response(id: req.id, r)
                    case .failure(let e): response = Response(id: req.id, op: op, error: e)
                    }
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

/// Synchronous NDJSON client. One connection; requests are sequential.
public final class MessageClient<Req: OpMessage, Reply: OpMessage>: @unchecked Sendable {
    private let conn: LineConnection

    /// Connect to `path`. `timeout` applies to every read/write (nil = none).
    public init(path: String, timeout: TimeInterval? = Defaults.clientTimeout) throws {
        conn = try UnixSocket.connect(path: path, timeout: timeout)
    }

    public func setTimeout(_ t: TimeInterval?) { conn.setReadTimeout(t) }

    /// Send a request and wait for its reply. Failure responses throw `WireError`;
    /// transport problems throw `SocketError`.
    public func call(_ message: Req) throws -> Reply {
        let id = try send(message)
        while true {
            let r = try next()
            guard r.id == id else { continue }
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
    public func next() throws -> Response<Reply> {
        guard let line = try conn.readLine() else { throw SocketError.closed }
        return try WireCoding.decode(Response<Reply>.self, line: line)
    }

    public func close() { conn.close() }
}

public typealias GateClient = MessageClient<GateRequest, GateReply>
public typealias GateServer = MessageServer<GateRequest, GateReply>
public typealias FanClient = MessageClient<FanRequest, FanReply>
public typealias FanServer = MessageServer<FanRequest, FanReply>
