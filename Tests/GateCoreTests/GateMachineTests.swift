import Foundation
import Testing
@testable import GateCore
import Shared

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

func req(_ session: String = "s1", cwd: String = "/p/a", max: TimeInterval? = nil, ticket: String? = nil,
         pid: Int32 = 100, socket: String? = nil) -> AcquireRequest {
    AcquireRequest(sessionId: session, cwd: cwd, command: "make", pid: pid, maxRuntimeSeconds: max,
                   ticket: ticket, messagingSocket: socket)
}

func granted(_ r: AcquireResult) -> UUID? {
    if case .granted(let id, _) = r { return id }
    return nil
}

func busy(_ r: AcquireResult) -> TicketInfo? {
    if case .busy(let t) = r { return t }
    return nil
}

/// Reference wrapper so mutating calls can sit inside `#expect`.
@dynamicMemberLookup
final class MBox {
    var m: GateMachine
    init(_ m: GateMachine) { self.m = m }
    subscript<T>(dynamicMember kp: WritableKeyPath<GateMachine, T>) -> T {
        get { m[keyPath: kp] }
        set { m[keyPath: kp] = newValue }
    }
    func acquire(_ r: AcquireRequest, now: Date) -> AcquireResult { m.acquire(r, now: now) }
    func heartbeat(_ r: JobHeartbeatRequest, now: Date) -> HeartbeatDirective { m.heartbeat(r, now: now) }
    func hookCheck(_ r: HookCheckRequest, now: Date) -> HookDecision { m.hookCheck(r, now: now) }
    func waitStatus(_ id: String, now: Date) -> WaitTicketResult { m.waitStatus(id, now: now) }
    func killJob(_ id: UUID, soft: Bool = false, now: Date) -> Bool { m.killJob(id, soft: soft, now: now) }
    func release(_ id: UUID, now: Date) { m.release(id, now: now) }
    func advance(now: Date) { m.advance(now: now) }
    @discardableResult func reap(dead: Set<Int32>, stopped: Set<Int32> = [], now: Date) -> [Lease] {
        m.reap(dead: dead, stopped: stopped, now: now)
    }
    func meeting(now: Date) { m.meeting(now: now) }
    func endWait(_ id: String, now: Date) { m.endWait(id, now: now) }
    func setGate(_ l: GateLevel, slots: Int?, now: Date) { m.setGate(l, slots: slots, now: now) }
    func setSettings(_ s: GateSettings, now: Date) { m.setSettings(s, now: now) }
    func ticketInfo(_ id: String, now: Date) -> TicketInfo? { m.ticketInfo(id, now: now) }
    func nextSlotETA(_ now: Date) -> Date? { m.nextSlotETA(now) }
    var effectiveSlots: Int { m.effectiveSlots }
    var freeSlots: Int { m.freeSlots }
}

func machine(slots: Int = 2, level: GateLevel = .on) -> MBox {
    MBox(GateMachine(settings: GateSettings(slots: slots), level: level))
}

@Suite struct SlotTests {
    @Test func grantsUpToSlotsThenBusy() throws {
        let m = machine()
        #expect(granted(m.acquire(req("a"), now: t0)) != nil)
        #expect(granted(m.acquire(req("b"), now: t0)) != nil)
        let t = try #require(busy(m.acquire(req("c"), now: t0)))
        #expect(t.id == "t1" && t.position == 1)
        #expect(m.leases.count == 2)
    }

    @Test func maxRuntimeDefaultAndCap() {
        let m = machine()
        _ = m.acquire(req("a"), now: t0)
        _ = m.acquire(req("b", max: 7200), now: t0)
        #expect(m.leases.map(\.maxRuntimeSeconds) == [900, 3600])
    }

    @Test func releaseFreesSlot() throws {
        let m = machine(slots: 1)
        let id = try #require(granted(m.acquire(req("a"), now: t0)))
        m.release(id, now: t0)
        #expect(m.leases.isEmpty)
        #expect(granted(m.acquire(req("b"), now: t0)) != nil)
    }

    @Test func reaperRemovesDeadPids() {
        let m = machine()
        _ = m.acquire(req("a", pid: 11), now: t0)
        _ = m.acquire(req("b", pid: 12), now: t0)
        m.reap(dead: [11], now: t0)
        #expect(m.leases.map(\.pid) == [12])
    }

    @Test func reaperRemovesSilentLeases() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a", pid: 11), now: t0)))
        _ = m.acquire(req("b", pid: 12), now: t0)
        _ = m.heartbeat(JobHeartbeatRequest(jobId: a, pgid: 77), now: t0 + 20)
        #expect(m.reap(dead: [], now: t0 + 30).isEmpty)
        let gone = m.reap(dead: [], now: t0 + 31)
        #expect(gone.map(\.pid) == [12] && m.leases.map(\.pid) == [11])
        #expect(m.reap(dead: [], now: t0 + 51).map(\.pgid) == [77])
    }

    @Test func stoppedCgateIsNotReapedForSilence() {
        let m = machine()
        _ = m.acquire(req("a", pid: 11), now: t0)
        #expect(m.reap(dead: [], stopped: [11], now: t0 + 100).isEmpty)
        #expect(m.reap(dead: [], now: t0 + 120).isEmpty)  // counted as seen at the stopped reap
        #expect(m.reap(dead: [11], stopped: [11], now: t0 + 121).map(\.pid) == [11])  // dead still reaped
    }
}

@Suite struct TicketTests {
    @Test func sameSessionCwdReusesTicketUnknownDoesNot() {
        let m = machine(slots: 1)
        _ = m.acquire(req("x"), now: t0)
        #expect(busy(m.acquire(req("s"), now: t0))?.id == "t1")
        #expect(busy(m.acquire(req("s"), now: t0))?.id == "t1")
        #expect(busy(m.acquire(req("s", cwd: "/other"), now: t0))?.id == "t2")
        #expect(busy(m.acquire(req("unknown"), now: t0))?.id == "t3")
        #expect(busy(m.acquire(req("unknown"), now: t0))?.id == "t4")
    }

    @Test func fifoHoldClaimAndFairness() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        #expect(busy(m.acquire(req("b"), now: t0))?.id == "t1")
        #expect(busy(m.acquire(req("c"), now: t0))?.id == "t2")
        m.release(a, now: t0 + 10)
        #expect(m.held == [HeldSlot(ticketId: "t1", until: t0 + 130)])
        // Newcomer cannot take the held slot, and c (t2) is still queued.
        #expect(busy(m.acquire(req("d"), now: t0 + 11))?.id == "t3")
        #expect(busy(m.acquire(req("c", ticket: "t2"), now: t0 + 11))?.position == 2)
        // b claims with its ticket.
        #expect(granted(m.acquire(req("b", ticket: "t1"), now: t0 + 12)) != nil)
        #expect(m.held.isEmpty)
        #expect(m.tickets.map(\.id) == ["t2", "t3"])
    }

    @Test func oneHoldPerFreeSlot() throws {
        let m = machine(slots: 2)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        let b = try #require(granted(m.acquire(req("b"), now: t0)))
        _ = m.acquire(req("c"), now: t0)
        _ = m.acquire(req("d"), now: t0)
        m.release(a, now: t0 + 1)
        m.release(b, now: t0 + 2)
        #expect(m.held == [HeldSlot(ticketId: "t1", until: t0 + 121), HeldSlot(ticketId: "t2", until: t0 + 122)])
        #expect(m.waitStatus("t1", now: t0 + 3) == .ready(ticket: "t1", heldUntil: t0 + 121))
        #expect(m.waitStatus("t2", now: t0 + 3) == .ready(ticket: "t2", heldUntil: t0 + 122))
        // Newcomer is busy while all free slots are held.
        #expect(busy(m.acquire(req("e"), now: t0 + 3))?.position == 3)
        #expect(granted(m.acquire(req("d", ticket: "t2"), now: t0 + 4)) != nil)
        // t1's hold expires on its own; the slot goes to the next ticket (e's t3).
        m.advance(now: t0 + 121)
        #expect(m.held.map(\.ticketId) == ["t3"])
        #expect(granted(m.acquire(req("e"), now: t0 + 122)) != nil)
        #expect(m.held.isEmpty && m.tickets.isEmpty && m.leases.count == 2)
    }

    @Test func freshAcquireBusyOnlyWhileFreeSlotsHeld() throws {
        let m = machine(slots: 2)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        _ = m.acquire(req("c"), now: t0)
        _ = m.acquire(req("d"), now: t0)
        m.release(a, now: t0)  // one free slot → held for t1; t2 still queued
        #expect(m.held.map(\.ticketId) == ["t1"] && m.freeSlots == 0)
        #expect(busy(m.acquire(req("x"), now: t0))?.id == "t3")
    }

    @Test func claimByOwnKeyWithoutTicketFlag() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        m.release(a, now: t0)
        #expect(granted(m.acquire(req("b"), now: t0 + 1)) != nil)
        #expect(m.tickets.isEmpty)
    }

    @Test func unclaimedHoldExpiresAndPassesOn() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        _ = m.acquire(req("c"), now: t0)
        m.release(a, now: t0)
        m.advance(now: t0 + 119)
        #expect(m.held.first?.ticketId == "t1")
        m.advance(now: t0 + 120)
        #expect(m.held == [HeldSlot(ticketId: "t2", until: t0 + 240)])
        #expect(m.acquire(req("b", ticket: "t1"), now: t0 + 121) == .ticketExpired(ticket: "t1"))
        #expect(m.acquire(req("x", ticket: "nope"), now: t0) == .ticketExpired(ticket: "nope"))
        m.advance(now: t0 + 240)
        #expect(m.held.isEmpty && m.tickets.isEmpty)
        #expect(granted(m.acquire(req("z"), now: t0 + 241)) != nil)
    }

    @Test func etaFromLeaseDeadlinesAndPosition() {
        let m = machine(slots: 2)
        _ = m.acquire(req("a", max: 600), now: t0)
        _ = m.acquire(req("b", max: 300), now: t0)
        #expect(m.nextSlotETA(t0) == t0 + 300)
        let t1 = busy(m.acquire(req("c"), now: t0))
        let t2 = busy(m.acquire(req("d"), now: t0))
        let t3 = busy(m.acquire(req("e"), now: t0))
        #expect(t1 == TicketInfo(id: "t1", position: 1, eta: t0 + 300, holdSeconds: 120))
        #expect(t2 == TicketInfo(id: "t2", position: 2, eta: t0 + 600, holdSeconds: 120))
        // Third in line: wraps around, plus one default max (15 min).
        #expect(t3 == TicketInfo(id: "t3", position: 3, eta: t0 + 300 + 900, holdSeconds: 120))
        // Raw deadlines: overdue ETAs don't move with the clock (L4).
        #expect(m.ticketInfo("t1", now: t0 + 400)?.eta == t0 + 300)
    }

    @Test func zeroSlotsClosesGate() throws {
        let m = machine(slots: 0)
        #expect(m.acquire(req("a"), now: t0) == .off(message: CgateMessage.noSlots))
        #expect(m.tickets.isEmpty && m.nextSlotETA(t0) == nil)
        // Slots set to 0 while a ticket waits: no ETA, no hold, claims answer off.
        let n = machine(slots: 1)
        _ = try #require(granted(n.acquire(req("a"), now: t0)))
        #expect(busy(n.acquire(req("b"), now: t0))?.eta != nil)
        n.m.setGate(.on, slots: 0, now: t0)
        #expect(n.ticketInfo("t1", now: t0)?.eta == nil && n.nextSlotETA(t0) == nil && n.held.isEmpty)
        #expect(n.acquire(req("b", ticket: "t1"), now: t0) == .off(message: CgateMessage.noSlots))
    }

    @Test func cancelTicketFreesHeldSlot() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        _ = m.acquire(req("c"), now: t0)
        m.m.cancelTicket("t1", now: t0)
        m.release(a, now: t0)
        #expect(m.tickets.map(\.id) == ["t2"] && m.held.first?.ticketId == "t2")
    }

    @Test func endedLeaseDropsItsUndeliveredNotices() throws {
        let m = machine(slots: 2)
        let a = try #require(granted(m.acquire(req("s", max: 3600), now: t0)))
        _ = try #require(granted(m.acquire(req("s", cwd: "/p/b", max: 60, pid: 7), now: t0)))
        #expect(m.killJob(a, soft: true, now: t0))
        m.advance(now: t0 + 61)  // b hits walltime
        #expect(m.notices.count == 2)
        m.release(a, now: t0 + 61)
        #expect(m.notices.count == 1)
        m.reap(dead: [7], now: t0 + 62)
        #expect(m.notices.isEmpty)
    }

    @Test func slotReadyNoticeOnlyWithoutWaiter() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        _ = m.acquire(req("c"), now: t0)
        m.waiters["t1"] = 1
        m.release(a, now: t0)
        #expect(m.notices.isEmpty)
        #expect(m.waitStatus("t1", now: t0) == .ready(ticket: "t1", heldUntil: t0 + 120))
        if case .pending(let i) = m.waitStatus("t2", now: t0) { #expect(i.position == 2) } else { Issue.record("not pending") }
        #expect(m.waitStatus("zz", now: t0) == .expired(ticket: "zz"))
        // No waiter on t2: when t1's hold expires, c gets a notice + push.
        m.outbox = []
        m.advance(now: t0 + 120)
        #expect(m.notices.map(\.kind) == [.slotReady(ticket: "t2")])
        #expect(m.outbox.map(\.sessionId) == ["c"])
        #expect(m.waitStatus("t2", now: t0 + 121) == .ready(ticket: "t2", heldUntil: t0 + 240))
        #expect(m.notices.isEmpty)
    }

    @Test func endedWaitLingersOneSecond() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        m.waiters["t1"] = 1
        m.endWait("t1", now: t0)  // poll ended pending; cgate wait reconnects shortly
        #expect(m.waiters["t1"] == nil)
        m.release(a, now: t0 + 0.5)
        #expect(m.notices.isEmpty && m.held.first?.ticketId == "t1")
    }

    @Test func lingerExpires() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        m.waiters["t1"] = 1
        m.endWait("t1", now: t0)
        m.release(a, now: t0 + 1)
        #expect(m.notices.map(\.kind) == [.slotReady(ticket: "t1")])
    }
}

@Suite struct LevelTests {
    @Test func noMoreDeniesNewKeepsRunning() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        m.setGate(.noMore, slots: nil, now: t0)
        #expect(m.effectiveSlots == 0 && m.settings.slots == 2)
        #expect(m.acquire(req("b"), now: t0) == .off(message: CgateMessage.gateOff))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0) == .continue)
        #expect(m.notices.isEmpty)
    }

    @Test func softStopNoticesOncePerSessionNoSignal() throws {
        let m = machine(slots: 3)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("a", cwd: "/p/b"), now: t0)
        _ = m.acquire(req("b"), now: t0)
        m.setGate(.softStop, slots: nil, now: t0)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0) == .softStop(reason: .userSoftStop))
        #expect(m.notices.map(\.sessionId) == ["a", "b"])
        #expect(m.notices.allSatisfy { $0.text == CgateMessage.softStopNotice })
        // Back on: soft-stop requests and undelivered soft-stop notices are withdrawn.
        m.setGate(.on, slots: nil, now: t0)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0) == .continue)
        #expect(m.notices.isEmpty)
    }

    @Test func meetingNeverSoftens() {
        let m = machine()
        m.meeting(now: t0)
        #expect(m.level == .noMore)
        for l in [GateLevel.softStop, .hardStop] {
            m.setGate(l, slots: nil, now: t0)
            m.meeting(now: t0)
            #expect(m.level == l)
        }
    }

    @Test func hardStopKills() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        m.setGate(.hardStop, slots: nil, now: t0)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a, pgid: 55), now: t0) == .hardStop(reason: .userHardStop))
        #expect(m.leases[0].pgid == 55 && m.leases[0].state == .killing)
        #expect(m.notices.map(\.text) == [CgateMessage.hardStopNotice])
    }

    @Test func gateOffTicketsKeepPlace() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        _ = m.acquire(req("b"), now: t0)
        m.setGate(.noMore, slots: nil, now: t0)
        m.release(a, now: t0)
        #expect(m.held.isEmpty && m.tickets.map(\.id) == ["t1"])
        m.setGate(.on, slots: 2, now: t0 + 5)
        #expect(m.held.first?.ticketId == "t1" && m.settings.slots == 2)
    }

    @Test func killJob() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        #expect(m.killJob(a, now: t0))
        #expect(!m.killJob(UUID(), now: t0))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0) == .hardStop(reason: .userKill))
        #expect(m.notices.count == 1)
    }

    @Test func softKillJobThenHard() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        let b = try #require(granted(m.acquire(req("b"), now: t0)))
        #expect(m.killJob(a, soft: true, now: t0))
        #expect(!m.killJob(UUID(), soft: true, now: t0))
        #expect(m.leases[0].state == .stopRequested && m.leases[0].stopReason == .userKill)
        #expect(m.leases[1].state == .running)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0) == .softStop(reason: .userKill))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: b), now: t0) == .continue)
        #expect(m.notices.map(\.text) == [CgateMessage.jobStopNotice(command: "make")])
        #expect(m.outbox.map(\.text) == [CgateMessage.jobStopNotice(command: "make")])
        #expect(m.killJob(a, soft: true, now: t0 + 1))  // repeat soft: no-op
        #expect(m.notices.count == 1 && m.leases[0].stopRequestedAt == t0)
        m.setGate(.on, slots: nil, now: t0 + 2)  // per-job stop survives gate back on
        #expect(m.leases[0].state == .stopRequested)
        #expect(m.killJob(a, now: t0 + 3))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 3) == .hardStop(reason: .userKill))
    }

    @Test func gateSoftStopAndWalltimeMarkStopRequested() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        let b = try #require(granted(m.acquire(req("b", max: 60), now: t0)))
        m.setGate(.softStop, slots: nil, now: t0)
        #expect(m.leases.allSatisfy { $0.state == .stopRequested })
        #expect(m.killJob(a, soft: true, now: t0))  // already requested: no extra notice
        #expect(!m.notices.contains { $0.text == CgateMessage.jobStopNotice(command: "make") })
        m.setGate(.on, slots: nil, now: t0)
        m.advance(now: t0 + 60)
        #expect(m.leases.first { $0.jobId == b }?.state == .stopRequested)
        #expect(m.leases.first { $0.jobId == a }?.state == .running)
    }

    @Test func settingsSanitized() {
        let m = machine()
        m.setSettings(GateSettings(slots: -3, patterns: ["x"], defaultMaxRuntimeSeconds: 9999,
                                   maxRuntimeCapSeconds: 600), now: t0)
        #expect(m.settings.slots == 0 && m.settings.defaultMaxRuntimeSeconds == 600)
        #expect(m.settings.patterns == ["x"])
        m.setSettings(GateSettings(ticketHoldSeconds: 1, walltimeGraceSeconds: 9999), now: t0)
        #expect(m.settings.ticketHoldSeconds == 30 && m.settings.walltimeGraceSeconds == 300)
        m.setSettings(GateSettings(ticketHoldSeconds: 9999, walltimeGraceSeconds: 0), now: t0)
        #expect(m.settings.ticketHoldSeconds == 600 && m.settings.walltimeGraceSeconds == 10)
    }

    @Test func holdFromSettings() throws {
        let m = machine(slots: 1)
        var s = m.settings
        s.ticketHoldSeconds = 90
        m.setSettings(s, now: t0)
        let a = try #require(granted(m.acquire(req("a"), now: t0)))
        let t = try #require(busy(m.acquire(req("b"), now: t0)))
        #expect(t.holdSeconds == 90 && CgateMessage.busy(t).contains("then held for you 90 s"))
        m.release(a, now: t0)
        #expect(m.held.first?.until == t0 + 90)
        #expect(m.notices.map(\.text) == [CgateMessage.slotReady(ticket: "t1", heldUntil: t0 + 90, now: t0)])
        #expect(m.notices[0].text.contains("claim within 90 s"))
        m.advance(now: t0 + 89)
        #expect(m.tickets.count == 1)
        m.advance(now: t0 + 90)
        #expect(m.tickets.isEmpty)
    }
}

@Suite struct WalltimeTests {
    @Test func softNoticeThenHardKillAfterGrace() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a", max: 60, socket: "/tmp/cc-socks/1.sock"), now: t0)))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 59) == .continue)
        m.outbox = []
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 60) == .softStop(reason: .walltime))
        #expect(m.notices.count == 1 && m.notices[0].text.contains("max runtime (1m) of `make` exceeded"))
        #expect(m.outbox == [Push(sessionId: "a", socket: "/tmp/cc-socks/1.sock", text: m.notices[0].text)])
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 119) == .softStop(reason: .walltime))
        #expect(m.notices.count == 1)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 120) == .hardStop(reason: .walltime))
    }

    @Test func graceFromSettings() throws {
        let m = machine()
        var s = m.settings
        s.walltimeGraceSeconds = 30
        m.setSettings(s, now: t0)
        let a = try #require(granted(m.acquire(req("a", max: 60), now: t0)))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 60) == .softStop(reason: .walltime))
        #expect(m.notices.map(\.text) == [CgateMessage.walltimeNotice(command: "make", max: 60, grace: 30)])
        #expect(m.notices[0].text.hasSuffix("killed in 30 s"))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 89) == .softStop(reason: .walltime))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 90) == .hardStop(reason: .walltime))
    }

    @Test func lateHeartbeatJumpsToKill() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a", max: 60), now: t0)))
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 500) == .hardStop(reason: .walltime))
        #expect(m.notices.count == 1)
    }

    @Test func walltimeOverridesSoftStopReason() throws {
        let m = machine()
        let a = try #require(granted(m.acquire(req("a", max: 60), now: t0)))
        m.setGate(.softStop, slots: nil, now: t0)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: a), now: t0 + 120) == .hardStop(reason: .walltime))
    }
}

@Suite struct ReattachTests {
    @Test func alwaysGrantedKeepsIdAndStart() {
        let m = machine(slots: 1, level: .noMore)
        let id = UUID()
        var r = req("a", max: 600)
        r.reattach = Reattach(jobId: id, startedAt: t0 - 100)
        #expect(m.acquire(r, now: t0) == .granted(jobId: id, maxRuntimeSeconds: 600))
        r.reattach = Reattach(jobId: UUID(), startedAt: t0)
        #expect(granted(m.acquire(r, now: t0)) != nil)  // above slot count
        #expect(m.leases[0].startedAt == t0 - 100 && m.leases[0].deadline == t0 + 500)
        r.reattach = Reattach(jobId: id, startedAt: t0)  // idempotent
        #expect(m.acquire(r, now: t0) == .granted(jobId: id, maxRuntimeSeconds: 600))
        #expect(m.leases.count == 2)
        #expect(m.heartbeat(JobHeartbeatRequest(jobId: UUID()), now: t0) == .unknownJob)
    }

    @Test func reattachUnderHardStopIsKilled() {
        let m = machine(level: .hardStop)
        var r = req("a")
        r.reattach = Reattach(jobId: UUID(), startedAt: t0)
        _ = m.acquire(r, now: t0)
        #expect(m.leases[0].state == .killing)
    }
}

@Suite struct HookCheckTests {
    func hc(_ cmd: String?, session: String = "s", tool: String = "Bash", cwd: String = "/p/a") -> HookCheckRequest {
        HookCheckRequest(sessionId: session, toolName: tool, command: cmd, cwd: cwd)
    }

    @Test func deniesHeavyWithRedirect() {
        let m = machine()
        #expect(m.hookCheck(hc("ls -la"), now: t0) == .allow)
        #expect(m.hookCheck(hc(nil, tool: "Read"), now: t0) == .allow)
        #expect(m.hookCheck(hc("cd x && swift test 2>&1 | tail"), now: t0)
            == .deny(reason: "Compute gate: heavy command. Re-run as: cgate run --max <estimate> -- "
                     + "'cd x && swift test 2>&1 | tail' with run_in_background: true"))
        #expect(m.hookCheck(hc("make it's"), now: t0)
            == .deny(reason: CommandMatcher.redirect("make it's")))
        #expect(CommandMatcher.redirect("make it's").contains(#"-- 'make it'\''s' with"#))
        #expect(m.hookCheck(hc("cgate run --max 5m -- 'swift test'"), now: t0) == .allow)
        #expect(m.hookCheck(hc("cgate run -- swift test 2>&1"), now: t0) == .allow)
        #expect(m.hookCheck(hc("cgate status; swift test"), now: t0)
            == .deny(reason: CommandMatcher.redirect("cgate status; swift test")))
        // Busy / off: the hook still only redirects; cgate run reports busy/off itself.
        m.setGate(.noMore, slots: nil, now: t0)
        #expect(m.hookCheck(hc("pytest"), now: t0) == .deny(reason: CommandMatcher.redirect("pytest")))
        #expect(m.leases.isEmpty && m.tickets.isEmpty)
    }

    @Test func noticeOnceAndClaimSuppressesSlotReady() throws {
        let m = machine(slots: 1)
        let a = try #require(granted(m.acquire(req("x"), now: t0)))
        _ = m.acquire(req("s"), now: t0)
        m.release(a, now: t0)
        #expect(m.hookCheck(hc("cgate run --ticket t1 -- make"), now: t0) == .allow)
        #expect(m.notices.isEmpty)
        _ = try #require(granted(m.acquire(req("s", ticket: "t1"), now: t0)))
        m.setGate(.softStop, slots: nil, now: t0)
        #expect(m.hookCheck(hc(nil, tool: "Edit"), now: t0) == .notice(text: CgateMessage.softStopNotice))
        #expect(m.hookCheck(hc(nil, tool: "Edit"), now: t0) == .allow)
        #expect(m.hookCheck(hc(nil, session: "other", tool: "Edit"), now: t0) == .allow)
    }
}

@Suite struct MatcherTests {
    @Test func cgateRunCommandTexts() {
        #expect(CommandMatcher.cgateRunCommands("cd x && cgate run --wait -- 'swift test' > /tmp/l 2>&1") == ["swift test"])
        #expect(CommandMatcher.cgateRunCommands("cgate run -- make all >log") == ["make all"])
        #expect(CommandMatcher.cgateRunCommands("cgate status; cgate wait --ticket t1; ls") == [])
        #expect(CommandMatcher.cgateRunCommands("echo 'cgate run -- x'") == [])
    }

    let p = Defaults.autoWrapPatterns

    @Test func matching() {
        for c in ["make", "make -j8", "/usr/bin/make", "swift test --filter X", "FOO=1 pytest -q",
                  "cd a && npm run build", "time cargo test", "./scripts/check.sh", "x | pytest",
                  "uv run pytest tests", "echo hi; xcodebuild -scheme A", "(cd a; make)", "env CC=clang make"] {
            #expect(CommandMatcher.matches(c, patterns: p), "\(c)")
        }
        for c in ["cmake ..", "echo pytest", "git commit -m 'make it'", "swift package resolve",
                  "npm install", "ls && echo 'a && make'", ""] {
            #expect(!CommandMatcher.matches(c, patterns: p), "\(c)")
        }
    }

    @Test func wrappedAndQuoting() {
        #expect(CommandMatcher.isWrapped("cgate run -- make"))
        #expect(CommandMatcher.isWrapped("FOO=1 ~/bin/cgate run --max 5m -- 'cd x && make' 2>&1"))
        #expect(!CommandMatcher.isWrapped("cd x && ~/bin/cgate run -- make"))
        #expect(!CommandMatcher.isWrapped("cgate status; swift test"))
        #expect(!CommandMatcher.isWrapped("make cgate"))
        #expect(CommandMatcher.shellQuote("echo 'a b'") == #"'echo '\''a b'\'''"#)
        #expect(CommandMatcher.mentionsTicket("cgate wait --ticket t3", "t3"))
        #expect(CommandMatcher.mentionsTicket("cgate run --ticket=t3 -- make", "t3"))
        #expect(CommandMatcher.mentionsTicket("cd x && cgate run --ticket t3 -- make", "t3"))
        #expect(!CommandMatcher.mentionsTicket("cgate run --ticket t31 -- make", "t3"))
        #expect(!CommandMatcher.mentionsTicket("echo t3", "t3"))
    }

    @Test func heredocBodiesSkipped() {
        let fp = ["cat <<EOF > notes.md\nrun make and swift test\nEOF",
                  "git commit -F - <<'EOF'\nmake\nEOF",
                  "cat <<-\"END\"\n\tpytest\n\tEND\necho done",
                  "cat <<A <<B\nmake\nA\npytest\nB"]
        for c in fp { #expect(!CommandMatcher.matches(c, patterns: p), "\(c)") }
        let fn = ["cat <<'EOF' > f\nfoo\nEOF\nmake",
                  "cat <<EOF | tee x\nhi\nEOF\nswift test",
                  "grep x <<< 'make' && pytest"]
        for c in fn { #expect(CommandMatcher.matches(c, patterns: p), "\(c)") }
    }

    @Test func harmlessPrefixesStripped() {
        for c in ["bash scripts/check.sh", "sh ./scripts/check.sh -v", "zsh -x check.sh",
                  "bash -c 'cd a && make'", "sh -lc \"swift test\"",
                  "timeout 600 swift test", "timeout -s KILL 10m pytest -x", "env CC=clang FOO=1 make",
                  "FOO=1 BAR=2 pytest", "uv run pytest", "uv run --with pytest-xdist -q pytest -n4",
                  "python -m pytest", "python3 -m pytest tests", "npx vitest run", "npx -y playwright test",
                  "pnpm exec vitest", "nohup timeout 5 uv run python3 -m pytest &"] {
            #expect(CommandMatcher.matches(c, patterns: p), "\(c)")
        }
        for c in ["bash -c 'echo make'", "timeout 5 ls", "uv run ruff check", "python3 -m http.server",
                  "npx prettier .", "sh setup.sh", "uv pip list"] {
            #expect(!CommandMatcher.matches(c, patterns: p), "\(c)")
        }
    }
}

@Suite struct AgentTests {
    func run(_ cmd: String, agent: String?, session: String = "s", cwd: String = "/p/a") -> HookCheckRequest {
        HookCheckRequest(sessionId: session, toolName: "Bash", command: cmd, cwd: cwd, agentId: agent)
    }

    func acq(_ cmd: String, session: String = "s", cwd: String = "/p/a", ticket: String? = nil) -> AcquireRequest {
        AcquireRequest(sessionId: session, cwd: cwd, command: cmd, pid: 1, ticket: ticket,
                       messagingSocket: "/tmp/cc-socks/s.sock")
    }

    @Test func matchNoMatchExpiry() throws {
        let m = machine(slots: 4)
        #expect(m.hookCheck(run("cgate run --max 5m -- 'swift test'", agent: "A"), now: t0) == .allow)
        _ = m.acquire(acq("make"), now: t0)  // different command: main session
        _ = m.acquire(acq("swift test"), now: t0 + 1)
        #expect(m.leases.map(\.agentId) == [nil, "A"])
        #expect(m.pendingAgents.isEmpty)  // consumed
        _ = m.hookCheck(run("cgate run -- swift build", agent: "B"), now: t0)
        _ = m.acquire(acq("swift build"), now: t0 + 16)  // expired
        #expect(m.leases.last?.agentId == nil)
        _ = m.hookCheck(run("cgate wait --ticket t1", agent: "C"), now: t0 + 20)  // only `run` attributes
        #expect(m.pendingAgents.isEmpty)
        _ = m.hookCheck(run("cgate run -- ls", agent: nil), now: t0 + 20)  // main session: stashed as nil
        #expect(m.pendingAgents.map(\.agentId) == [nil])
    }

    /// Hook line → the exact command text cgate sends; one entry per invocation.
    @Test func exactCommandTextAttribution() throws {
        let big = String(repeating: "x", count: 5000)
        let cases: [(hook: String, acquired: [String])] = [
            (#"cgate run --max 5m -- pytest -k "a or b""#, ["pytest -k 'a or b'"]),
            (#"cgate run -- 'echo "it'\''s"'"#, [#"echo "it's""#]),
            (#"cgate run -- 'a'\''b' c"#, [#"'a'\''b' c"#]),
            ("cgate run -- 'echo \(big)'", [CommandText.capped("echo \(big)")]),
            ("cgate run -- a; cgate run -- b", ["a", "b"]),
            ("bash -c 'cgate run -- make test 2>&1' > /tmp/log", ["make test"]),
        ]
        for c in cases {
            let m = machine(slots: 4)
            _ = m.hookCheck(run(c.hook, agent: "A"), now: t0)
            for cmd in c.acquired { _ = m.acquire(acq(cmd), now: t0 + 1) }
            #expect(m.leases.map(\.agentId) == c.acquired.map { _ in "A" }, "\(c.hook)")
            #expect(m.pendingAgents.isEmpty, "\(c.hook)")
        }
    }

    @Test func mainSessionDoesNotTakeSubagentEntry() throws {
        for order in [false, true] {
            let m = machine(slots: 4)
            _ = m.hookCheck(run("cgate run -- make test", agent: "A"), now: t0)
            _ = m.hookCheck(run("cgate run -- make", agent: nil), now: t0)
            if order {
                _ = m.acquire(acq("make test"), now: t0 + 1)
                _ = m.acquire(acq("make"), now: t0 + 1)
            } else {
                _ = m.acquire(acq("make"), now: t0 + 1)
                _ = m.acquire(acq("make test"), now: t0 + 1)
            }
            #expect(m.leases.map(\.agentId) == (order ? ["A", nil] : [nil, "A"]))
        }
    }

    @Test func twoSubagentsSameSession() throws {
        let m = machine(slots: 4)
        _ = m.hookCheck(run("cgate run -- 'make'", agent: "A", cwd: "/p/a"), now: t0)
        _ = m.hookCheck(run("cd /p/b && cgate run -- 'make'", agent: "B", cwd: "/p/b"), now: t0)
        _ = m.acquire(acq("make", cwd: "/p/b"), now: t0)
        _ = m.acquire(acq("make", cwd: "/p/a"), now: t0)
        #expect(m.leases.map(\.agentId) == ["B", "A"])
    }

    @Test func ticketsAndNoticesPerAgentNoPush() throws {
        let m = machine(slots: 1)
        let main = try #require(granted(m.acquire(acq("make"), now: t0)))
        _ = m.hookCheck(run("cgate run -- 'make'", agent: "A"), now: t0)
        let ta = try #require(busy(m.acquire(acq("make"), now: t0)))
        let tm = try #require(busy(m.acquire(acq("make"), now: t0)))  // main: own ticket, not A's
        #expect(ta.id == "t1" && tm.id == "t2" && m.tickets.map(\.agentId) == ["A", nil])
        m.outbox = []
        m.release(main, now: t0)
        #expect(m.notices.map(\.agentId) == ["A"] && m.outbox.isEmpty)  // no push into the parent
        #expect(m.hookCheck(run("ls", agent: nil), now: t0) == .allow)
        #expect(m.hookCheck(run("ls", agent: "B"), now: t0) == .allow)
        guard case .notice = m.hookCheck(run("ls", agent: "A"), now: t0) else { Issue.record("no notice"); return }
        // A claims with its ticket (no hook attribution needed); stop notices also go to A only.
        let a = try #require(granted(m.acquire(acq("make", ticket: "t1"), now: t0 + 1)))
        #expect(m.leases.first?.agentId == "A")
        #expect(m.killJob(a, soft: true, now: t0 + 1))
        #expect(m.notices.map(\.agentId) == ["A"] && m.outbox.isEmpty)
    }

    @Test func oldClientsWithoutAgentUnchanged() throws {
        let m = machine(slots: 1)
        _ = m.acquire(acq("make"), now: t0)
        m.setGate(.softStop, slots: nil, now: t0)
        #expect(m.outbox.count == 1 && m.notices.first?.agentId == nil)
        #expect(m.hookCheck(run("ls", agent: nil), now: t0) == .notice(text: CgateMessage.softStopNotice))
    }
}
