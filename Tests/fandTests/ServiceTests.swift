import Darwin
import Foundation
import Testing
@testable import fand
@testable import Shared

private func tempSocketPath() -> String {
    "/tmp/cm-test-fand-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
}

private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
    let end = Date() + timeout
    while Date() < end {
        if cond() { return true }
        usleep(20_000)
    }
    return cond()
}

private func makeService(_ smc: FakeSMC, authorize: @escaping FanServer.Authorizer = { _ in true })
    -> FandService {
    let hub = StatusHub()
    let c = FanController(hw: FanHardware.discover(smc), thermal: { .nominal }, onChange: { hub.publish($0) })
    return FandService(controller: c, hub: hub, path: tempSocketPath(), authorize: authorize)
}

@Suite(.serialized) struct ServiceTests {
    @Test func setModeStatusHeartbeat() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        var st = stat()
        #expect(stat(svc.server.path, &st) == 0 && (st.st_mode & 0o777) == 0o666)

        let client = try FanClient(path: svc.server.path)
        defer { client.close() }
        guard case .setMode(let s) = try client.call(.setMode(SetModeRequest(mode: .max))) else {
            Issue.record("wrong reply"); return
        }
        #expect(s.mode == .max && smc.value("F0Md") == 1)
        #expect(try client.call(.heartbeat) == .heartbeat)
        guard case .status(let s2) = try client.call(.status) else { Issue.record("wrong reply"); return }
        #expect(s2.mode == .max && s2.lastHeartbeat != nil)
    }

    @Test func setModeCurveClampedOrRejected() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        let client = try FanClient(path: svc.server.path)
        defer { client.close() }
        let wild = FanCurve(lowTemp: 30, highTemp: 200, hysteresis: 3, tick: 0.01)
        guard case .setMode(let s) = try client.call(.setMode(SetModeRequest(mode: .performance, curve: wild)))
        else { Issue.record("wrong reply"); return }
        let clamped = FanCurve(lowTemp: 40, highTemp: 95, hysteresis: 3, tick: Defaults.fanCurve.tick)
        #expect(s.curve == clamped && svc.controller.curve == clamped)

        // Malformed curve (JSON can't carry NaN; a wrong type is the realistic bad input): error, no change.
        let conn = try UnixSocket.connect(path: svc.server.path, timeout: 2)
        defer { conn.close() }
        let line = #"{"v":\#(ProtocolVersion.fand),"id":"9","op":"setMode","body":{"mode":"max","curve":{"lowTemp":"x"}}}"#
        try conn.writeLine(Data(line.utf8))
        let r = try WireCoding.decode(Response<FanReply>.self, line: #require(try conn.readLine()))
        #expect(throws: WireError.self) { try r.result.get() }
        #expect(svc.controller.curve == clamped && svc.controller.currentMode == .performance)
    }

    @Test func controlDisconnectRevertsToAuto() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        let client = try FanClient(path: svc.server.path)
        _ = try client.call(.setMode(SetModeRequest(mode: .performance)))
        #expect(svc.controller.currentMode == .performance)
        client.close()  // app crash
        #expect(waitUntil { svc.controller.currentMode == .auto })
        #expect(smc.value("F0Md") == 0)
    }

    @Test func statusOnlyDisconnectKeepsMode() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        let control = try FanClient(path: svc.server.path)
        defer { control.close() }
        _ = try control.call(.setMode(SetModeRequest(mode: .max)))
        let other = try FanClient(path: svc.server.path)
        _ = try other.call(.status)
        other.close()
        #expect(waitUntil { svc.server.connectionCount == 1 })
        #expect(svc.controller.currentMode == .max)
    }

    @Test func subscribeStreamsOnChange() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        let sub = try FanClient(path: svc.server.path)
        defer { sub.close() }
        let id = try sub.send(.subscribe)
        let first = try sub.next()
        #expect(first.id == id)
        guard case .success(.subscribe(let s0)) = first.result else { Issue.record("no push"); return }
        #expect(s0.mode == .auto)
        #expect(waitUntil { svc.hub.count == 1 })

        let control = try FanClient(path: svc.server.path)
        defer { control.close() }
        _ = try control.call(.setMode(SetModeRequest(mode: .max)))
        guard case .success(.subscribe(let s1)) = try sub.next().result else { Issue.record("no push"); return }
        #expect(s1.mode == .max)
        svc.controller.tick(now: Monotonic.now())
        guard case .success(.subscribe(let s2)) = try sub.next().result else { Issue.record("no push"); return }
        #expect(s2.mode == .max)
    }

    @Test func subscriberGoneIsCleanedUp() throws {
        let smc = FakeSMC()
        let svc = makeService(smc)
        try svc.start()
        defer { svc.stop() }
        let sub = try FanClient(path: svc.server.path)
        _ = try sub.send(.subscribe)
        _ = try sub.next()
        #expect(waitUntil { svc.hub.count == 1 })
        sub.close()
        svc.controller.tick(now: Monotonic.now())  // push fails → stream ends
        #expect(waitUntil {
            svc.controller.tick(now: Monotonic.now())
            return svc.hub.count == 0 && svc.server.connectionCount == 0
        })
    }

    @Test func unauthorizedPeerRejected() throws {
        let smc = FakeSMC()
        let svc = makeService(smc, authorize: { _ in false })
        try svc.start()
        defer { svc.stop() }
        let client = try FanClient(path: svc.server.path)
        defer { client.close() }
        #expect(throws: WireError(.unauthorized, "peer not allowed")) {
            try client.call(.setMode(SetModeRequest(mode: .max)))
        }
        #expect(smc.value("F0Md") == 0)
    }

    @Test func peerAuthRules() {
        #expect(PeerAuth.isAllowed(peerUID: 501, consoleUID: 501))
        #expect(!PeerAuth.isAllowed(peerUID: 501, consoleUID: 502))
        #expect(!PeerAuth.isAllowed(peerUID: 501, consoleUID: nil))
        #expect(PeerAuth.isAllowed(peerUID: 0, consoleUID: nil))
        #expect(!PeerAuth.isAllowed(peerUID: nil, consoleUID: 501))
        // On a dev machine with a logged-in user, the console UID is ours.
        #expect(PeerAuth.consoleUID() == getuid())
    }
}
