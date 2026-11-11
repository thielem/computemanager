import Foundation
import Shared

/// Undelivered notice (delivered once via `hookCheck`, also pushed via the messaging socket).
struct Notice: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case stop
        case slotReady(ticket: String)
    }

    var sessionId: String
    var text: String
    var kind: Kind
}

/// Messaging-socket push requested by the machine; performed by `GateService` outside its lock.
/// `socket` nil → the service tries its session resolver.
struct Push: Sendable, Equatable {
    var sessionId: String
    var socket: String?
    var text: String
}

/// Pure gate state machine (PLAN §2 GATE, §5, §6). No I/O, no clock: every mutating call gets
/// `now`. Invariant: held tickets are a prefix of `tickets` (holds go to the oldest tickets).
struct GateMachine: Sendable {
    static let unknownSession = "unknown"
    /// A lease without heartbeat for this long is reaped (cgate hung or gone).
    static let heartbeatTimeout: TimeInterval = 30
    /// A `cgate wait` counts as waiting this long after its poll ends (reconnect gap).
    static let waiterLinger: TimeInterval = 1

    var level: GateLevel
    var settings: GateSettings
    var leases: [Lease] = []
    /// FIFO; `held` covers its first `held.count` entries.
    var tickets: [Ticket] = []
    /// One hold per free slot, for the oldest tickets (each with its own expiry).
    var held: [HeldSlot] = []
    var notices: [Notice] = []
    /// Active `waitTicket` long-polls per ticket id (no slot-ready notice/push while waited on).
    var waiters: [String: Int] = [:]
    /// Ended `waitTicket` polls still count as waiting until this time (L5).
    var waitLinger: [String: Date] = [:]
    /// Last heartbeat (or grant) per job.
    var lastSeen: [UUID: Date] = [:]
    /// Last messaging socket seen per session (from `acquire`).
    var sessionSockets: [String: String] = [:]
    /// Pushes produced since the last drain.
    var outbox: [Push] = []
    var nextTicket = 1

    init(settings: GateSettings, level: GateLevel) {
        self.settings = Self.sanitized(settings)
        self.level = level
    }

    // MARK: Derived

    var effectiveSlots: Int { level == .on ? settings.slots : 0 }
    /// Slots neither leased nor held (negative when over-committed, e.g. after reattach).
    var freeSlots: Int { effectiveSlots - leases.count - held.count }
    /// Tickets waiting without a held slot.
    var queuedTickets: ArraySlice<Ticket> { tickets.dropFirst(held.count) }

    func hold(of id: String) -> HeldSlot? { held.first { $0.ticketId == id } }

    /// Raw lease deadlines, ascending (not clamped to now, so ETAs stay stable per tick).
    private var deadlines: [Date] { leases.map(\.deadline).sorted() }

    func nextSlotETA(_ now: Date) -> Date? {
        level.isOff ? nil : deadlines.first
    }

    /// Position 1-based in the FIFO. ETA: held → when the hold started; queued #j (0-based,
    /// excl. held) → j-th smallest lease deadline, wrapping around with `defaultMax` per round.
    func ticketInfo(_ id: String, now: Date) -> TicketInfo? {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return nil }
        if let h = hold(of: id) {
            return TicketInfo(id: id, position: i + 1, eta: h.until.addingTimeInterval(-Defaults.ticketHold))
        }
        let j = i - held.count
        let d = deadlines
        var eta: Date?
        if !level.isOff, !d.isEmpty {
            eta = d[j % d.count].addingTimeInterval(Double(j / d.count) * settings.defaultMaxRuntimeSeconds)
        }
        return TicketInfo(id: id, position: i + 1, eta: eta)
    }

    func snapshot(now: Date) -> GateStatus {
        GateStatus(level: level, slots: settings.slots, effectiveSlots: effectiveSlots,
                   leases: leases, tickets: tickets.compactMap { ticketInfo($0.id, now: now) },
                   heldSlot: held.first, nextSlotETA: nextSlotETA(now),
                   pendingNotices: notices.map { PendingNotice(sessionId: $0.sessionId, text: $0.text) },
                   settings: settings)
    }

    // MARK: Time

    /// Walltime transitions + hold expiry/assignment. Called before every op and by the tick.
    mutating func advance(now: Date) {
        for i in leases.indices where leases[i].state != .killing {
            let l = leases[i]
            guard now >= l.deadline else { continue }
            if l.stopReason != .walltime {
                leases[i].state = .stopRequested
                leases[i].stopReason = .walltime
                leases[i].stopRequestedAt = now
                notify(l.sessionId, CgateMessage.walltimeNotice(command: l.command, max: l.maxRuntimeSeconds),
                       socket: l.messagingSocket)
            }
            if now >= l.deadline.addingTimeInterval(Defaults.walltimeGrace) {
                leases[i].state = .killing
            }
        }
        promote(now: now)
    }

    /// Expire unclaimed holds; hold one free slot per queued ticket, oldest first.
    mutating func promote(now: Date) {
        for h in held where now >= h.until { drop(ticket: h.ticketId) }
        waitLinger = waitLinger.filter { $0.value > now }
        if level.isOff { held = [] }  // tickets keep their place
        while freeSlots > 0, let next = queuedTickets.first {
            let until = now.addingTimeInterval(Defaults.ticketHold)
            held.append(HeldSlot(ticketId: next.id, until: until))
            if !isWaited(next.id, now: now) {
                notify(next.sessionId, CgateMessage.slotReady(ticket: next.id, heldUntil: until),
                       kind: .slotReady(ticket: next.id), socket: next.socket(in: self))
            }
        }
    }

    func isWaited(_ id: String, now: Date) -> Bool {
        waiters[id, default: 0] > 0 || (waitLinger[id].map { now < $0 } ?? false)
    }

    /// A `waitTicket` poll ended; it still counts as waiting for `waiterLinger`.
    mutating func endWait(_ id: String, now: Date) {
        waiters[id, default: 1] -= 1
        if waiters[id] == 0 { waiters[id] = nil }
        waitLinger[id] = now.addingTimeInterval(Self.waiterLinger)
    }

    private mutating func drop(ticket id: String) {
        tickets.removeAll { $0.id == id }
        notices.removeAll { $0.kind == .slotReady(ticket: id) }
        held.removeAll { $0.ticketId == id }
    }

    // MARK: Ops

    mutating func acquire(_ r: AcquireRequest, now: Date) -> AcquireResult {
        advance(now: now)
        if let s = r.messagingSocket, r.sessionId != Self.unknownSession { sessionSockets[r.sessionId] = s }
        if let re = r.reattach {
            if let l = leases.first(where: { $0.jobId == re.jobId }) {
                lastSeen[l.jobId] = now
                return .granted(jobId: l.jobId, maxRuntimeSeconds: l.maxRuntimeSeconds)
            }
            let max = effectiveMax(r.maxRuntimeSeconds)
            leases.append(makeLease(r, id: re.jobId, start: re.startedAt, max: max))
            lastSeen[re.jobId] = now
            applyLevel(toLeaseAt: leases.count - 1)
            advance(now: now)
            return .granted(jobId: re.jobId, maxRuntimeSeconds: max)
        }
        guard !level.isOff else { return .off(message: CgateMessage.gateOff) }

        if let t = r.ticket {
            if hold(of: t) != nil || (queuedTickets.first?.id == t && freeSlots > 0) {
                return grant(r, consuming: t, now: now)
            }
            if let info = ticketInfo(t, now: now) { return .busy(info) }
            return .ticketExpired(ticket: t)
        }
        if let own = ownTicket(session: r.sessionId, cwd: r.cwd) {
            if hold(of: own.id) != nil { return grant(r, consuming: own.id, now: now) }
            return .busy(ticketInfo(own.id, now: now)!)
        }
        if queuedTickets.isEmpty, freeSlots > 0 { return grant(r, consuming: nil, now: now) }
        return .busy(issueTicket(session: r.sessionId, cwd: r.cwd, now: now))
    }

    mutating func release(_ jobId: UUID, now: Date) {
        leases.removeAll { $0.jobId == jobId }
        lastSeen[jobId] = nil
        advance(now: now)
    }

    mutating func heartbeat(_ r: JobHeartbeatRequest, now: Date) -> HeartbeatDirective {
        advance(now: now)
        guard let i = leases.firstIndex(where: { $0.jobId == r.jobId }) else { return .unknownJob }
        lastSeen[r.jobId] = now
        if let p = r.pgid { leases[i].pgid = p }
        switch leases[i].state {
        case .killing: return .hardStop(reason: leases[i].stopReason ?? .userKill)
        case .stopRequested: return .softStop(reason: leases[i].stopReason ?? .userSoftStop)
        case .running, .done: return .continue
        }
    }

    mutating func hookCheck(_ r: HookCheckRequest, now: Date) -> HookDecision {
        advance(now: now)
        if let cmd = r.command {
            // Claiming / waiting for a ticket makes its slot-ready notice redundant.
            notices.removeAll {
                guard case .slotReady(let t) = $0.kind, $0.sessionId == r.sessionId else { return false }
                return CommandMatcher.mentionsTicket(cmd, t)
            }
        }
        let mine = notices.filter { $0.sessionId == r.sessionId }
        if !mine.isEmpty {
            notices.removeAll { $0.sessionId == r.sessionId }
            return .notice(text: mine.map(\.text).joined(separator: "\n"))
        }
        // K1 (user decision): never rewrite, never allow; heavy unwrapped Bash → deny with the
        // exact `cgate run` line to use. Busy / gate off is reported by `cgate run` itself.
        guard r.toolName == "Bash", let cmd = r.command, !CommandMatcher.isWrapped(cmd),
              CommandMatcher.matches(cmd, patterns: settings.patterns) else { return .allow }
        return .deny(reason: CommandMatcher.redirect(cmd))
    }

    /// Long-poll step for `waitTicket`. `ready` also clears the slot-ready notice.
    mutating func waitStatus(_ id: String, now: Date) -> WaitTicketResult {
        advance(now: now)
        if let h = hold(of: id) {
            notices.removeAll { $0.kind == .slotReady(ticket: id) }
            return .ready(ticket: id, heldUntil: h.until)
        }
        guard let info = ticketInfo(id, now: now) else { return .expired(ticket: id) }
        return .pending(info)
    }

    mutating func setGate(_ level: GateLevel, slots: Int?, now: Date) {
        if let slots { settings.slots = Self.clampSlots(slots) }
        self.level = level
        if level == .on {
            notices.removeAll { $0.text == CgateMessage.softStopNotice }
            for i in leases.indices where leases[i].state == .stopRequested && leases[i].stopReason == .userSoftStop {
                leases[i].state = .running
                leases[i].stopReason = nil
                leases[i].stopRequestedAt = nil
            }
        }
        for i in leases.indices { applyLevel(toLeaseAt: i) }
        advance(now: now)
    }

    /// Meeting started: on → noMore; never softens softStop/hardStop (or touches noMore).
    mutating func meeting(now: Date) {
        if level == .on { setGate(.noMore, slots: nil, now: now) } else { advance(now: now) }
    }

    /// False if the job is unknown. `soft`: only a running job becomes `stopRequested` (notice, no
    /// signal); a job already stop-requested or killing is left as is.
    mutating func killJob(_ jobId: UUID, soft: Bool = false, now: Date) -> Bool {
        advance(now: now)
        guard let i = leases.firstIndex(where: { $0.jobId == jobId }) else { return false }
        if soft {
            if leases[i].state == .running {
                leases[i].state = .stopRequested
                leases[i].stopReason = .userKill
                leases[i].stopRequestedAt = now
                notify(leases[i].sessionId, CgateMessage.jobStopNotice(command: leases[i].command),
                       socket: leases[i].messagingSocket)
            }
        } else if leases[i].state != .killing {
            leases[i].state = .killing
            leases[i].stopReason = .userKill
            leases[i].stopRequestedAt = now
            notify(leases[i].sessionId, Self.killNotice(leases[i].command), socket: leases[i].messagingSocket)
        }
        return true
    }

    mutating func setSettings(_ s: GateSettings, now: Date) {
        settings = Self.sanitized(s)
        advance(now: now)
    }

    /// Remove leases whose cgate pid is dead (GATE-6) or that sent no heartbeat for
    /// `heartbeatTimeout`. A `stopped` cgate (SIGSTOP/Ctrl-Z/debugger) is exempt from the silence
    /// rule and counts as seen now. Returns the removed leases (the service kills their pgids).
    @discardableResult
    mutating func reap(dead: Set<Int32>, stopped: Set<Int32> = [], now: Date) -> [Lease] {
        for l in leases where stopped.contains(l.pid) { lastSeen[l.jobId] = now }
        let gone = leases.filter { l in
            dead.contains(l.pid) || now.timeIntervalSince(lastSeen[l.jobId] ?? now) > Self.heartbeatTimeout
        }
        let ids = Set(gone.map(\.jobId))
        leases.removeAll { ids.contains($0.jobId) }
        ids.forEach { lastSeen[$0] = nil }
        advance(now: now)
        return gone
    }

    /// Treat every lease as just seen (after system sleep nobody could heartbeat).
    mutating func touchAll(now: Date) {
        for l in leases { lastSeen[l.jobId] = now }
    }

    // MARK: Helpers

    static func killNotice(_ command: String) -> String {
        "compute gate: user killed your heavy job `\(command.count <= 60 ? command : String(command.prefix(59)) + "…")`. "
            + "Continue without it or stop and report"
    }

    private mutating func applyLevel(toLeaseAt i: Int) {
        switch level {
        case .on, .noMore: break
        case .softStop:
            guard leases[i].state == .running else { return }
            leases[i].state = .stopRequested
            leases[i].stopReason = .userSoftStop
            notify(leases[i].sessionId, CgateMessage.softStopNotice, socket: leases[i].messagingSocket)
        case .hardStop:
            guard leases[i].state != .killing else { return }
            leases[i].state = .killing
            leases[i].stopReason = .userHardStop
            notify(leases[i].sessionId, CgateMessage.hardStopNotice, socket: leases[i].messagingSocket)
        }
    }

    /// Queue a notice (deduplicated per session + text) and a push.
    private mutating func notify(_ session: String, _ text: String, kind: Notice.Kind = .stop, socket: String?) {
        let n = Notice(sessionId: session, text: text, kind: kind)
        guard !notices.contains(n) else { return }
        if session != Self.unknownSession { notices.append(n) }
        let sock = socket ?? sessionSockets[session]
        if session != Self.unknownSession || sock != nil {
            outbox.append(Push(sessionId: session, socket: sock, text: text))
        }
    }

    private func ownTicket(session: String, cwd: String) -> Ticket? {
        guard session != Self.unknownSession else { return nil }
        return tickets.first { $0.sessionId == session && $0.cwd == cwd }
    }

    private mutating func issueTicket(session: String, cwd: String, now: Date) -> TicketInfo {
        let t = Ticket(id: "t\(nextTicket)", sessionId: session, cwd: cwd, issuedAt: now)
        nextTicket += 1
        tickets.append(t)
        return ticketInfo(t.id, now: now)!
    }

    private mutating func grant(_ r: AcquireRequest, consuming ticket: String?, now: Date) -> AcquireResult {
        if let ticket { drop(ticket: ticket) }
        let max = effectiveMax(r.maxRuntimeSeconds)
        let lease = makeLease(r, id: UUID(), start: now, max: max)
        leases.append(lease)
        lastSeen[lease.jobId] = now
        promote(now: now)
        return .granted(jobId: lease.jobId, maxRuntimeSeconds: max)
    }

    private func makeLease(_ r: AcquireRequest, id: UUID, start: Date, max: TimeInterval) -> Lease {
        Lease(jobId: id, sessionId: r.sessionId, cwd: r.cwd, command: r.command, pid: r.pid,
              pgid: r.pgid, startedAt: start, maxRuntimeSeconds: max, autoWrapped: r.autoWrapped,
              messagingSocket: r.messagingSocket)
    }

    private func effectiveMax(_ requested: TimeInterval?) -> TimeInterval {
        let v = requested ?? settings.defaultMaxRuntimeSeconds
        return min(max(v, 1), settings.maxRuntimeCapSeconds)
    }

    static func clampSlots(_ n: Int) -> Int { min(max(n, 0), 64) }

    static func sanitized(_ s: GateSettings) -> GateSettings {
        var s = s
        s.slots = clampSlots(s.slots)
        s.maxRuntimeCapSeconds = max(s.maxRuntimeCapSeconds, 1)
        s.defaultMaxRuntimeSeconds = min(max(s.defaultMaxRuntimeSeconds, 1), s.maxRuntimeCapSeconds)
        return s
    }
}

private extension Ticket {
    /// Known messaging socket for the ticket's session.
    func socket(in m: GateMachine) -> String? {
        m.sessionSockets[sessionId] ?? m.leases.first { $0.sessionId == sessionId }?.messagingSocket
    }
}
