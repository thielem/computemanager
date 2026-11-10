import Darwin
import Foundation
import Testing
@testable import Shared

private func tempSocketPath() -> String {
    // Keep it short: sun_path is 104 bytes.
    "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
}

@Suite(.serialized) struct SocketTests {
    @Test func gateRoundTrip() throws {
        let path = tempSocketPath()
        let server = GateServer(path: path) { req, ctx in
            #expect(ctx.peer?.uid == getuid())
            switch req {
            case .hookCheck(let h): return .success(.hookCheck(.wrap(newCommand: "cgate run -- " + (h.command ?? ""))))
            case .status: return .failure(.notImplemented("status"))
            default: return .failure(WireError(.invalidState, "nope"))
            }
        }
        try server.start()
        defer { server.stop() }

        var st = stat()
        #expect(stat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)

        let client = try GateClient(path: path)
        defer { client.close() }
        let r = try client.call(.hookCheck(HookCheckRequest(sessionId: "s", toolName: "Bash", command: "make")))
        #expect(r == .hookCheck(.wrap(newCommand: "cgate run -- make")))
        #expect(throws: WireError.notImplemented("status")) { try client.call(.status) }
        // Connection stays usable after an error reply.
        #expect(throws: WireError(.invalidState, "nope")) { try client.call(.meeting) }
    }

    @Test func malformedLineGetsBadRequest() throws {
        let path = tempSocketPath()
        let server = GateServer(path: path) { req, _ in .failure(.notImplemented(req.op)) }
        try server.start()
        defer { server.stop() }
        let conn = try UnixSocket.connect(path: path, timeout: 2)
        defer { conn.close() }
        try conn.writeLine(Data(#"{"v":1,"id":"7","op":"bogus"}"#.utf8))
        let r1 = try WireCoding.decode(Response<GateReply>.self, line: #require(try conn.readLine()))
        #expect(r1.id == "7")
        #expect(throws: WireError(.unknownOp, "bogus")) { try r1.result.get() }
        try conn.writeLine(Data("not json".utf8))
        let r2 = try WireCoding.decode(Response<GateReply>.self, line: #require(try conn.readLine()))
        #expect(throws: WireError.self) { try r2.result.get() }
    }

    @Test func unauthorizedPeer() throws {
        let path = tempSocketPath()
        let server = FanServer(path: path, authorize: { _ in false }) { _, _ in .success(.heartbeat) }
        try server.start()
        defer { server.stop() }
        let client = try FanClient(path: path)
        defer { client.close() }
        #expect(throws: WireError(.unauthorized, "peer not allowed")) { try client.call(.heartbeat) }
    }

    @Test func subscribeStream() throws {
        let path = tempSocketPath()
        let st = FanStatus(mode: .auto, fans: [], temps: Temperatures(), thermalState: .nominal,
                           lastHeartbeat: nil)
        let server = FanServer(path: path) { req, ctx in
            guard case .subscribe = req else { return .failure(.notImplemented(req.op)) }
            try? ctx.push(.subscribe(st))
            try? ctx.push(.subscribe(st))
            return .success(.subscribe(st))
        }
        try server.start()
        defer { server.stop() }
        let client = try FanClient(path: path)
        defer { client.close() }
        let id = try client.send(.subscribe)
        for _ in 0..<3 {
            let r = try client.next()
            #expect(r.id == id)
            #expect(try r.result.get() == .subscribe(st))
        }
    }

    @Test func unauthorizedPeerIsDisconnected() throws {
        let path = tempSocketPath()
        let server = FanServer(path: path, authorize: { _ in false }) { _, _ in .success(.heartbeat) }
        try server.start()
        defer { server.stop() }
        let client = try FanClient(path: path)
        defer { client.close() }
        #expect(throws: WireError(.unauthorized, "peer not allowed")) { try client.call(.heartbeat) }
        #expect(throws: SocketError.self) { try client.call(.heartbeat) }
    }

    @Test func partialLinesAreReassembled() throws {
        let path = tempSocketPath()
        let server = GateServer(path: path) { req, _ in .failure(.notImplemented(req.op)) }
        try server.start()
        defer { server.stop() }
        let conn = try UnixSocket.connect(path: path, timeout: 2)
        defer { conn.close() }
        let full = Array(#"{"v":1,"id":"p","op":"status"}"#.utf8) + [UInt8(ascii: "\n")]
        for chunk in [full[0..<5], full[5..<20], full[20...]] {
            _ = Array(chunk).withUnsafeBytes { write(conn.fd, $0.baseAddress, $0.count) }
            usleep(20_000)
        }
        let r = try WireCoding.decode(Response<GateReply>.self, line: #require(try conn.readLine()))
        #expect(r.id == "p")
        #expect(throws: WireError.notImplemented("status")) { try r.result.get() }
    }

    @Test func readLineLimits() throws {
        func pair() -> (LineConnection, LineConnection) {
            var fds: [Int32] = [0, 0]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            let r = LineConnection(fd: fds[0])
            r.setReadTimeout(1)
            return (r, LineConnection(fd: fds[1]))
        }
        func raw(_ c: LineConnection, _ s: String) {
            _ = Array(s.utf8).withUnsafeBytes { write(c.fd, $0.baseAddress, $0.count) }
        }
        // Complete line over the limit.
        let (r1, w1) = pair()
        try w1.writeLine(Data(String(repeating: "x", count: 100).utf8))
        #expect(throws: SocketError.lineTooLong) { try r1.readLine(maxBytes: 50) }
        // Partial line (no newline yet) already over the limit.
        let (r2, w2) = pair()
        raw(w2, String(repeating: "y", count: 80))
        #expect(throws: SocketError.lineTooLong) { try r2.readLine(maxBytes: 50) }
        // Partial line then EOF.
        let (r3, w3) = pair()
        raw(w3, "abc")
        w3.close()
        #expect(throws: SocketError.closed) { try r3.readLine() }
        // Two lines in one write, the second completed later.
        let (r4, w4) = pair()
        raw(w4, "one\ntw")
        #expect(try r4.readLine() == Data("one".utf8))
        raw(w4, "o\n")
        #expect(try r4.readLine() == Data("two".utf8))
        for c in [r1, w1, r2, w2, r3, r4, w4] { c.close() }
    }

    @Test func oversizedLineGetsBadRequestAndClose() throws {
        let path = tempSocketPath()
        let server = GateServer(path: path) { req, _ in .failure(.notImplemented(req.op)) }
        try server.start()
        defer { server.stop() }
        let conn = try UnixSocket.connect(path: path, timeout: 5)
        defer { conn.close() }
        // Writer thread: the server may close before we finish writing.
        let big = Data(repeating: UInt8(ascii: "x"), count: Defaults.maxLineBytes + 1)
        Thread { _ = try? conn.writeLine(big) }.start()
        let r = try WireCoding.decode(Response<GateReply>.self, line: #require(try conn.readLine()))
        #expect(throws: WireError(.badRequest, "line too long")) { try r.result.get() }
    }

    @Test func clientCallHasOverallDeadline() throws {
        // Server trickles bytes without ever finishing a line: per-syscall timeouts never fire.
        let path = tempSocketPath()
        let server = UnixSocketServer(path: path)
        try server.start { conn in
            for _ in 0..<40 {
                let n = [UInt8(ascii: "x")].withUnsafeBytes { write(conn.fd, $0.baseAddress, 1) }
                guard n == 1 else { return }
                usleep(100_000)
            }
        }
        defer { server.stop() }
        let client = try GateClient(path: path, timeout: Defaults.hookClientTimeout)
        defer { client.close() }
        let t0 = Date()
        #expect(throws: SocketError.self) { try client.call(.status) }
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    @Test func clientTimesOutOnSilentServer() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(path: path)
        try server.start { conn in _ = try? conn.readLine(); usleep(3_000_000) }
        defer { server.stop() }
        let client = try GateClient(path: path, timeout: Defaults.hookClientTimeout)
        defer { client.close() }
        let t0 = Date()
        #expect(throws: SocketError.timeout) { try client.call(.status) }
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    @Test func nonPositiveTimeoutIsNotInfinite() throws {
        let path = tempSocketPath()
        let server = UnixSocketServer(path: path)
        try server.start { conn in _ = try? conn.readLine(); usleep(3_000_000) }
        defer { server.stop() }
        let client = try GateClient(path: path, timeout: 0)
        defer { client.close() }
        let t0 = Date()
        #expect(throws: SocketError.timeout) { try client.call(.status) }
        #expect(Date().timeIntervalSince(t0) < 1.0)
    }

    @Test func staleSocketIsReplacedLiveServerIsNot() throws {
        let path = tempSocketPath()
        // Stale: a bound socket file with no listener.
        let fd = try UnixSocket.makeSocket()
        #expect(try UnixSocket.withAddress(path) { bind(fd, $0, $1) } == 0)
        close(fd)
        let server = GateServer(path: path) { req, _ in .failure(.notImplemented(req.op)) }
        try server.start()
        defer { server.stop() }
        // Live: second server refuses and must not remove the first one's socket.
        let second = GateServer(path: path) { _, _ in .success(.release) }
        #expect(throws: SocketError.alreadyRunning(path)) { try second.start() }
        second.stop()
        let client = try GateClient(path: path)
        defer { client.close() }
        #expect(throws: WireError.notImplemented("status")) { try client.call(.status) }
    }

    @Test func connectionCapAndConcurrency() throws {
        let path = tempSocketPath()
        let server = GateServer(path: path, maxConnections: 4) { req, _ in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return .failure(.notImplemented(req.op))
        }
        try server.start()
        defer { server.stop() }
        let clients = try (0..<4).map { _ in try GateClient(path: path) }
        defer { clients.forEach { $0.close() } }
        // All 4 served concurrently.
        let group = DispatchGroup()
        let ok = Counter()
        for c in clients {
            group.enter()
            Thread {
                do { _ = try c.call(.status) } catch let e as WireError where e == .notImplemented("status") {
                    ok.bump()
                } catch {}
                group.leave()
            }.start()
        }
        #expect(group.wait(timeout: .now() + 5) == .success)
        #expect(ok.value == 4)
        // The 5th is closed right away.
        let extra = try GateClient(path: path)
        defer { extra.close() }
        #expect(throws: SocketError.self) { try extra.call(.status) }
        #expect(server.connectionCount == 4)
    }

    @Test func onDisconnectFiresWithConnectionId() throws {
        let path = tempSocketPath()
        let seen = Box<ConnectionID>(), gone = Box<ConnectionID>()
        let sem = DispatchSemaphore(value: 0)
        let server = FanServer(path: path, onDisconnect: { id, peer in
            #expect(peer?.uid == getuid())
            gone.set(id)
            sem.signal()
        }) { _, ctx in
            seen.set(ctx.connectionId)
            return .success(.heartbeat)
        }
        try server.start()
        defer { server.stop() }
        let client = try FanClient(path: path)
        _ = try client.call(.heartbeat)
        client.close()
        #expect(sem.wait(timeout: .now() + 2) == .success)
        #expect(seen.get() != nil && seen.get() == gone.get())
    }

    @Test func stalledSubscriberEndsStream() throws {
        let path = tempSocketPath()
        let st = FanStatus(mode: .auto, fans: [], temps: Temperatures(), thermalState: .nominal,
                           lastHeartbeat: nil)
        let ended = DispatchSemaphore(value: 0)
        let server = FanServer(path: path) { _, ctx in
            while (try? ctx.push(.subscribe(st))) != nil {}
            ended.signal()
            return .success(.subscribe(st))
        }
        try server.start()
        defer { server.stop() }
        let client = try FanClient(path: path)
        defer { client.close() }
        try client.send(.subscribe)  // never reads
        #expect(ended.wait(timeout: .now() + Defaults.serverSendTimeout + 3) == .success)
    }

    @Test func connectToMissingSocketFails() {
        #expect(throws: SocketError.self) { try GateClient(path: "/tmp/cm-missing-\(getpid()).sock") }
    }
}

private final class Counter: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

private final class Box<T: Sendable>: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var v: T?
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return v }
}
