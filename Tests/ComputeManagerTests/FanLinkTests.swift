import Foundation
import Shared
import Testing
@testable import ComputeManager

/// Fake fand: records (op, connection) and streams status on `subscribe`.
final class FakeFand: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var log: [(FanRequest, ConnectionID)] = []
    let server: FanServer

    init(path: String) {
        let box = Box()
        server = FanServer(path: path) { req, ctx in
            box.fand?.record(req, ctx.connectionId)
            let st = FanStatus(mode: .auto, fans: [], temps: Temperatures(pcoreMax: 60),
                               thermalState: .nominal, lastHeartbeat: nil)
            switch req {
            case .subscribe:
                while (try? ctx.push(.subscribe(st))) != nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return .success(.subscribe(st))
            case .setMode(let m):
                var s = st
                s.mode = m.mode
                return .success(.setMode(s))
            case .heartbeat: return .success(.heartbeat)
            case .status: return .success(.status(st))
            }
        }
        box.fand = self
    }

    private final class Box: @unchecked Sendable { weak var fand: FakeFand? }

    func record(_ r: FanRequest, _ c: ConnectionID) { lock.withLock { log.append((r, c)) } }
    var requests: [FanRequest] { lock.withLock { log.map(\.0) } }
    func connections(_ op: String) -> Set<ConnectionID> {
        lock.withLock { Set(log.filter { $0.0.op == op }.map(\.1)) }
    }
}

private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return cond()
}

@Suite(.serialized) struct FanLinkTests {
    let path = "/tmp/cm-test-b-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"

    @Test func separateConnectionsHeartbeatAndQuitAuto() async throws {
        let fand = FakeFand(path: path)
        try fand.server.start()
        defer { fand.server.stop() }
        let link = FanLink(path: path, heartbeatInterval: 0.1, minBackoff: 0.05, maxBackoff: 0.2)
        let got = Locked<FanStatus?>(nil)
        link.onStatus = { s in got.set(s) }
        link.start()
        link.setMode(.performance)
        #expect(await waitUntil { fand.requests.contains(.setMode(SetModeRequest(mode: .performance))) })
        #expect(await waitUntil { fand.requests.filter { $0 == .heartbeat }.count >= 2 })
        #expect(await waitUntil { got.get() != nil })
        let sub = fand.connections("subscribe"), ctl = fand.connections("heartbeat")
        #expect(sub.count == 1 && ctl.count == 1 && sub.isDisjoint(with: ctl))
        link.shutdown()
        #expect(fand.requests.last == .setMode(SetModeRequest(mode: .auto)))
    }

    @Test func reconnectResendsMode() async throws {
        let first = FakeFand(path: path)
        try first.server.start()
        let link = FanLink(path: path, heartbeatInterval: 0.1, minBackoff: 0.05, maxBackoff: 0.2)
        let reachable = Locked(true)
        link.onStatus = { s in reachable.set(s != nil) }
        link.start()
        link.setMode(.max)
        #expect(await waitUntil { first.requests.contains(.setMode(SetModeRequest(mode: .max))) })
        first.server.stop()
        #expect(await waitUntil { !reachable.get() })

        let second = FakeFand(path: path)
        try second.server.start()
        defer { second.server.stop() }
        #expect(await waitUntil { second.requests.contains(.setMode(SetModeRequest(mode: .max))) })
        #expect(await waitUntil { second.requests.contains(.heartbeat) && reachable.get() })
        link.shutdown()
    }

    /// FakeFand always reports Auto (like a watchdog revert): the link asks again, rate-limited.
    @Test func revertedModeIsResentRateLimited() async throws {
        let fand = FakeFand(path: path)
        try fand.server.start()
        defer { fand.server.stop() }
        let link = FanLink(path: path, heartbeatInterval: 0.1, minBackoff: 0.05, maxBackoff: 0.2,
                           resendInterval: 0.3)
        link.start()
        link.setMode(.performance)
        let perf = { fand.requests.filter { $0 == .setMode(SetModeRequest(mode: .performance)) }.count }
        #expect(await waitUntil { perf() >= 3 })
        let before = perf()
        try? await Task.sleep(for: .milliseconds(600))
        // Subscribe pushes every 50 ms; the limit keeps re-sends to ~1 per 0.3 s.
        #expect(perf() - before <= 3)
        link.shutdown()
    }

    @Test func unreachableReportsNil() async {
        let link = FanLink(path: path, heartbeatInterval: 0.1, minBackoff: 0.05, maxBackoff: 0.1)
        let calls = Locked(0)
        link.onStatus = { s in if s == nil { calls.set(calls.get() + 1) } }
        link.start()
        #expect(await waitUntil { calls.get() >= 2 })
        link.shutdown()
    }
}

final class Locked<T: Sendable>: @unchecked Sendable {  // guarded by `lock`
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
