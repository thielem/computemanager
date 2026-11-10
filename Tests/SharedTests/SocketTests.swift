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

    @Test func connectToMissingSocketFails() {
        #expect(throws: SocketError.self) { try GateClient(path: "/tmp/cm-missing-\(getpid()).sock") }
    }
}
