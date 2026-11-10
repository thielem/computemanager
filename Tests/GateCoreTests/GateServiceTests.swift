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
                pollWindow: 0.5, pollStep: 0.02, autoTick: false,
                signalGroup: { _, _ in -1 }, killGrace: 0.3)  // never signal real groups by default
}

/// `sh -c <script>` in its own process group; reaped by a background thread.
func spawnGroup(_ script: String) -> pid_t {
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
    posix_spawnattr_setpgroup(&attr, 0)
    let argv = ["/bin/sh", "-c", script].map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    precondition(posix_spawn(&pid, "/bin/sh", nil, &attr, argv, nil) == 0)
    Thread.detachNewThread { var st: Int32 = 0; waitpid(pid, &st, 0) }
    return pid
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
        _ = await svc.handle(.heartbeat(JobHeartbeatRequest(jobId: try #require(await leaseId(svc, pid: 1)))))
        svc.tick()
        guard case .success(.status(let s)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s.leases.map(\.pid) == [1])
        #expect(s.leases[0].state == .stopRequested && s.pendingNotices.count == 1)
    }

    @Test func reapedOrphanGroupGetsTermThenKill() async throws {
        let clock = FakeClock(t0)
        let svc = GateService(settings: GateSettings(slots: 2), level: .on, clock: { clock.now },
                              isAlive: { $0 != 666 }, pusher: .none, pollWindow: 0.5, autoTick: false,
                              killGrace: 0.3)
        // TERM-ignoring group: only the SIGKILL escalation ends it.
        let g = spawnGroup("trap '' TERM; sleep 30 & sleep 30; wait")
        defer { kill(-g, SIGKILL) }
        _ = await svc.handle(.acquire(req("a", pid: 666)))  // cgate pid dead
        let id = try #require(await leaseId(svc, pid: 666))
        _ = await svc.handle(.heartbeat(JobHeartbeatRequest(jobId: id, pgid: g)))
        #expect(kill(-g, 0) == 0)
        svc.tick()
        #expect(waitUntil(3) { kill(-g, 0) == -1 && errno == ESRCH })
        guard case .success(.status(let s)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s.leases.isEmpty)
    }

    @Test func silentLeaseReapedAfterTimeout() async throws {
        let clock = FakeClock(t0)
        let signals = Recorder<String>()
        let svc = GateService(settings: GateSettings(slots: 2), level: .on, clock: { clock.now },
                              isAlive: { _ in true }, pusher: .none, pollWindow: 0.5, autoTick: false,
                              signalGroup: { g, s in signals.add("\(g):\(s)"); return 0 }, killGrace: 0.05)
        _ = await svc.handle(.acquire(req("a", pid: 1)))
        let id = try #require(await leaseId(svc, pid: 1))
        _ = await svc.handle(.heartbeat(JobHeartbeatRequest(jobId: id, pgid: 4242)))
        clock.advance(30)
        svc.tick()
        guard case .success(.status(let s1)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s1.leases.count == 1)
        clock.advance(6)  // 36 s silent, next reaper run
        svc.tick()
        guard case .success(.status(let s2)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s2.leases.isEmpty)
        #expect(waitUntil { signals.all == ["4242:0", "4242:\(SIGTERM)", "4242:0", "4242:\(SIGKILL)"] })
    }

    @Test func stoppedCgateKeepsItsLease() async throws {
        let clock = FakeClock(t0)
        let stopped = Recorder<Bool>()
        stopped.add(true)
        let svc = GateService(settings: GateSettings(slots: 2), level: .on, clock: { clock.now },
                              isAlive: { _ in true }, pusher: .none, pollWindow: 0.5, autoTick: false,
                              signalGroup: { _, _ in -1 }, isStopped: { _ in stopped.all.last! })
        _ = await svc.handle(.acquire(req("a", pid: 1)))
        clock.advance(100)
        svc.tick()
        guard case .success(.status(let s1)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s1.leases.count == 1)
        stopped.add(false)
        clock.advance(31)
        svc.tick()
        guard case .success(.status(let s2)) = await svc.handle(.status) else { Issue.record(); return }
        #expect(s2.leases.isEmpty)
    }

    @Test func noSigkillWhenGroupLeaderChanged() async throws {
        let clock = FakeClock(t0)
        let signals = Recorder<String>()
        let starts = Recorder<UInt64>()
        starts.add(1)
        let svc = GateService(settings: GateSettings(slots: 2), level: .on, clock: { clock.now },
                              isAlive: { $0 != 666 }, pusher: .none, pollWindow: 0.5, autoTick: false,
                              signalGroup: { g, s in
                                  signals.add("\(g):\(s)")
                                  if s == SIGTERM { starts.add(2) }  // pid reused during the grace
                                  return 0
                              }, killGrace: 0.05, startTime: { _ in starts.all.last })
        _ = await svc.handle(.acquire(req("a", pid: 666)))
        let id = try #require(await leaseId(svc, pid: 666))
        _ = await svc.handle(.heartbeat(JobHeartbeatRequest(jobId: id, pgid: 4242)))
        svc.tick()
        usleep(300_000)
        #expect(signals.all == ["4242:0", "4242:\(SIGTERM)", "4242:0"])
    }

    @Test func realProbesSeeStoppedProcessAndStartTime() {
        let g = spawnGroup("sleep 30")
        defer { kill(-g, SIGKILL) }
        #expect(waitUntil { GateService.pidStartTime(g) != nil })
        #expect(!GateService.pidStopped(g))
        kill(g, SIGSTOP)
        #expect(waitUntil { GateService.pidStopped(g) })
        #expect(GateService.pidStartTime(g) == GateService.pidStartTime(g))
        #expect(GateService.pidStartTime(-1) == nil)
    }

    @Test func tickDuringGraceDoesNotFireOnChange() async throws {
        let clock = FakeClock(t0)
        let svc = makeService(clock: clock)
        _ = await svc.handle(.acquire(req("a", max: 60)))
        _ = await svc.handle(.acquire(req("b")))  // queued ticket with an ETA
        let seen = Recorder<GateStatus>()
        svc.onChange = { seen.add($0) }
        let beat = JobHeartbeatRequest(jobId: try #require(await leaseId(svc, pid: 100)))
        clock.advance(61)
        _ = await svc.handle(.heartbeat(beat))  // → stopRequested (one change)
        #expect(waitUntil { seen.all.count == 1 })
        for _ in 0..<5 {
            clock.advance(1)
            _ = await svc.handle(.heartbeat(beat))
            svc.tick()
        }
        usleep(100_000)
        #expect(seen.all.count == 1)
    }

    @Test func meetingDoesNotSoftenStops() async {
        let svc = makeService(clock: FakeClock(t0))
        _ = await svc.handle(.setGate(SetGateRequest(level: .hardStop)))
        guard case .success(.meeting(let s)) = await svc.handle(.meeting) else { Issue.record(); return }
        #expect(s.level == .hardStop)
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
        #expect(reply == .hookCheck(.deny(reason: CommandMatcher.redirect("make"))))
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

func leaseId(_ svc: GateService, pid: Int32) async -> UUID? {
    guard case .success(.status(let s)) = await svc.handle(.status) else { return nil }
    return s.leases.first { $0.pid == pid }?.jobId
}
