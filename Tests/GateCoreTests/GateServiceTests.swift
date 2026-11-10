import Darwin
import Foundation
import Testing
@testable import GateCore
import Shared

final class FakeClock: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var t: Date
    init(_ t: Date) { self.t = t }
    var now: Date { lock.withLock { t } }
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
}

final class Recorder<T: Sendable>: @unchecked Sendable {  // guarded by lock
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ x: T) { lock.withLock { items.append(x) } }
    var all: [T] { lock.withLock { items } }
}

func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
    let end = Date() + timeout
    while Date() < end {
        if cond() { return true }
        usleep(20_000)
    }
    return cond()
}

func makeService(slots: Int = 1, clock: FakeClock, pushes: Recorder<String>? = nil,
                 alive: @escaping @Sendable (Int32) -> Bool = { _ in true }) -> GateService {
    GateService(settings: GateSettings(slots: slots), level: .on, clock: { clock.now }, isAlive: alive,
                pusher: NoticePusher(push: { s, t in pushes?.add("\(s)|\(t)") },
                                     resolveSocket: { "/fake/\($0).sock" }),
                pollWindow: 0.5, pollStep: 0.02, autoTick: false)
}

@Suite struct GateServiceTests {
    @Test func publicInitServesStatus() async throws {
        let r = await GateService(settings: GateSettings(), level: .noMore).handle(.status)
        guard case .success(.status(let s)) = r else { Issue.record("\(r)"); return }
        #expect(s.level == .noMore && s.effectiveSlots == 0 && s.slots == 2)
    }

    @Test func onChangeFiresOnlyOnChange() async throws {
        let clock = FakeClock(t0)
        let svc = makeService(clock: clock)
        let seen = Recorder<GateStatus>()
        svc.onChange = { seen.add($0) }
        guard case .success(.acquire(.granted(let id, _))) = await svc.handle(.acquire(req("a"))) else {
            Issue.record("not granted"); return
        }
        _ = await svc.handle(.heartbeat(JobHeartbeatRequest(jobId: id)))
        _ = await svc.handle(.status)
        #expect(waitUntil { seen.all.count == 1 })
        _ = await svc.handle(.release(ReleaseRequest(jobId: id, exitCode: 0, reason: .exited)))
        #expect(waitUntil { seen.all.count == 2 })
        #expect(seen.all.map(\.leases.count) == [1, 0])
    }

    @Test func killJobUnknownIsInvalidState() async {
        let svc = makeService(clock: FakeClock(t0))
        let r = await svc.handle(.killJob(KillJobRequest(jobId: UUID())))
        guard case .failure(let e) = r else { Issue.record("\(r)"); return }
        #expect(e.code == .invalidState)
    }

    @Test func meetingSetsNoMore() async {
        let svc = makeService(clock: FakeClock(t0))
        guard case .success(.meeting(let s)) = await svc.handle(.meeting) else { Issue.record(); return }
        #expect(s.level == .noMore)
    }

    @Test func waitTicketLongPollReadyPendingExpired() async throws {
        let clock = FakeClock(t0)
        let svc = makeService(clock: clock)
        guard case .success(.acquire(.granted(let id, _))) = await svc.handle(.acquire(req("a"))) else {
            Issue.record(); return
        }
        guard case .success(.acquire(.busy(let t))) = await svc.handle(.acquire(req("b"))) else {
            Issue.record(); return
        }
        // Times out → pending.
        guard case .success(.waitTicket(.pending(let i))) = await svc.handle(.waitTicket(WaitTicketRequest(ticket: t.id))) else {
            Issue.record(); return
        }
        #expect(i.id == t.id)
        // Release while waiting → ready.
        async let waited = svc.handle(.waitTicket(WaitTicketRequest(ticket: t.id)))
        try await Task.sleep(nanoseconds: 100_000_000)
        _ = await svc.handle(.release(ReleaseRequest(jobId: id, exitCode: 0, reason: .exited)))
        #expect(await waited == .success(.waitTicket(.ready(ticket: t.id, heldUntil: t0 + 120))))
        // Waiter present → no slot-ready notice queued.
        guard case .success(.status(let s)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s.pendingNotices.isEmpty && s.heldSlot?.ticketId == t.id)
        clock.advance(121)
        svc.tick()
        #expect(await svc.handle(.waitTicket(WaitTicketRequest(ticket: t.id)))
            == .success(.waitTicket(.expired(ticket: t.id))))
    }

    @Test func noticesArePushed() async throws {
        let clock = FakeClock(t0)
        let pushes = Recorder<String>()
        let svc = makeService(slots: 2, clock: clock, pushes: pushes)
        _ = await svc.handle(.acquire(req("a", socket: "/tmp/cc-socks/9.sock")))
        _ = await svc.handle(.acquire(req("b")))
        _ = await svc.handle(.setGate(SetGateRequest(level: .softStop)))
        #expect(waitUntil { pushes.all.count == 2 })
        #expect(Set(pushes.all) == ["/tmp/cc-socks/9.sock|\(CgateMessage.softStopNotice)",
                                   "/fake/b.sock|\(CgateMessage.softStopNotice)"])
    }

    @Test func tickRunsWalltimeAndReaper() async throws {
        let clock = FakeClock(t0)
        let svc = makeService(slots: 2, clock: clock, alive: { $0 != 666 })
        _ = await svc.handle(.acquire(req("a", max: 60, pid: 1)))
        _ = await svc.handle(.acquire(req("b", pid: 666)))
        clock.advance(61)
        svc.tick()
        guard case .success(.status(let s)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s.leases.map(\.pid) == [1])
        #expect(s.leases[0].state == .stopRequested && s.pendingNotices.count == 1)
    }

    @Test func socketServerRoundTrip() async throws {
        let path = "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let svc = makeService(clock: FakeClock(t0))
        let server = svc.makeServer(path: path)
        try server.start()
        defer { server.stop() }
        let reply = try await Task.detached {
            let c = try GateClient(path: path)
            defer { c.close() }
            return try c.call(.hookCheck(HookCheckRequest(sessionId: "s", toolName: "Bash", command: "make")))
        }.value
        #expect(reply == .hookCheck(.wrap(newCommand: "cgate run --session s -- make")))
    }
}

@Suite struct MessagingSocketTests {
    @Test func sendsAuthAndUserLines() throws {
        let path = "/tmp/cm-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        let lines = Recorder<String>()
        let server = UnixSocketServer(path: path)
        try server.start { conn in
            while let l = try? conn.readLine() { lines.add(String(decoding: l, as: UTF8.self)) }
        }
        defer { server.stop() }
        try MessagingSocket.send(path: path, token: "tok", text: "hi \"there\"")
        #expect(waitUntil { lines.all.count == 2 })
        let auth = try JSONSerialization.jsonObject(with: Data(lines.all[0].utf8)) as? [String: String]
        #expect(auth == ["type": "auth", "token": "tok"])
        let msg = try JSONSerialization.jsonObject(with: Data(lines.all[1].utf8)) as? [String: Any]
        let inner = msg?["message"] as? [String: String]
        #expect(msg?["type"] as? String == "user" && inner == ["role": "user", "content": "hi \"there\""])
    }

    @Test func liveOnlyTargetsClaudeSockets() {
        #expect(MessagingSocket.isClaudeSocket("/tmp/cc-socks/123.sock"))
        #expect(!MessagingSocket.isClaudeSocket("/tmp/cm-test-1.sock"))
        #expect(!MessagingSocket.isClaudeSocket("/tmp/cc-socks/../x.sock"))
    }

    @Test func sessionRegistryLookup() throws {
        let dir = NSTemporaryDirectory() + "cm-sessions-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data(#"{"pid":5,"sessionId":"abc","messagingSocketPath":"/tmp/cc-socks/5.sock"}"#.utf8)
            .write(to: URL(fileURLWithPath: dir + "/5.json"))
        #expect(ClaudeSessions.messagingSocket(for: "abc", directory: dir) == "/tmp/cc-socks/5.sock")
        #expect(ClaudeSessions.messagingSocket(for: "zzz", directory: dir) == nil)
    }
}
