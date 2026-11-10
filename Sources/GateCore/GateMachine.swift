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
/// `now`. Invariant: the held ticket (if any) is `tickets.first`.
struct GateMachine: Sendable {
    static let unknownSession = "unknown"

    var level: GateLevel
    var settings: GateSettings
    var leases: [Lease] = []
    /// FIFO; `held` (if set) refers to `tickets.first`.
    var tickets: [Ticket] = []
    var held: HeldSlot?
    var notices: [Notice] = []
    /// Active `waitTicket` long-polls per ticket id (no slot-ready notice/push while waited on).
    var waiters: [String: Int] = [:]
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
    var freeSlots: Int { effectiveSlots - leases.count - (held == nil ? 0 : 1) }
    /// Tickets waiting without a held slot.
    var queuedTickets: ArraySlice<Ticket> { held == nil ? tickets[...] : tickets.dropFirst() }

    /// Lease deadlines (≥ now), ascending.
    private func deadlines(_ now: Date) -> [Date] {
        leases.map { max($0.deadline, now) }.sorted()
    }

    func nextSlotETA(_ now: Date) -> Date? {
        level.isOff ? nil : deadlines(now).first
    }

    /// Position 1-based in the FIFO. ETA: held → now; queued #j (0-based, excl. held) →
    /// j-th smallest lease deadline, wrapping around with `defaultMax` per extra round.
    func ticketInfo(_ id: String, now: Date) -> TicketInfo? {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return nil }
        if held?.ticketId == id { return TicketInfo(id: id, position: 1, eta: now) }
        let j = i - (held == nil ? 0 : 1)
        let d = deadlines(now)
        var eta: Date?
        if !level.isOff, !d.isEmpty {
            eta = d[j % d.count].addingTimeInterval(Double(j / d.count) * settings.defaultMaxRuntimeSeconds)
        }
        return TicketInfo(id: id, position: i + 1, eta: eta)
    }

    func snapshot(now: Date) -> GateStatus {
        GateStatus(level: level, slots: settings.slots, effectiveSlots: effectiveSlots,
                   leases: leases, tickets: tickets.compactMap { ticketInfo($0.id, now: now) },
                   heldSlot: held, nextSlotETA: nextSlotETA(now),
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

    /// Expire an unclaimed hold; hold a free slot for the oldest ticket.
    mutating func promote(now: Date) {
        if let h = held, now >= h.until {
            drop(ticket: h.ticketId)
        }
        if level.isOff { held = nil }  // ticket keeps its place at the front
        guard held == nil, let first = tickets.first, freeSlots > 0 else { return }
        let until = now.addingTimeInterval(Defaults.ticketHold)
        held = HeldSlot(ticketId: first.id, until: until)
        if waiters[first.id, default: 0] == 0 {
            notify(first.sessionId, CgateMessage.slotReady(ticket: first.id, heldUntil: until),
                   kind: .slotReady(ticket: first.id), socket: first.socket(in: self))
        }
    }

    private mutating func drop(ticket id: String) {
        tickets.removeAll { $0.id == id }
        notices.removeAll { $0.kind == .slotReady(ticket: id) }
        if held?.ticketId == id { held = nil }
    }

    // MARK: Ops

    mutating func acquire(_ r: AcquireRequest, now: Date) -> AcquireResult {
        advance(now: now)
        if let s = r.messagingSocket, r.sessionId != Self.unknownSession { sessionSockets[r.sessionId] = s }
        if let re = r.reattach {
            if let l = leases.first(where: { $0.jobId == re.jobId }) {
                return .granted(jobId: l.jobId, maxRuntimeSeconds: l.maxRuntimeSeconds)
            }
            let max = effectiveMax(r.maxRuntimeSeconds)
            leases.append(makeLease(r, id: re.jobId, start: re.startedAt, max: max))
            applyLevel(toLeaseAt: leases.count - 1)
            advance(now: now)
            return .granted(jobId: re.jobId, maxRuntimeSeconds: max)
        }
        guard !level.isOff else { return .off(message: CgateMessage.gateOff) }

        if let t = r.ticket {
            if held?.ticketId == t { return grant(r, consuming: t, now: now) }
            if let info = ticketInfo(t, now: now) { return .busy(info) }
            return .ticketExpired(ticket: t)
        }
        if let own = ownTicket(session: r.sessionId, cwd: r.cwd) {
            if held?.ticketId == own.id { return grant(r, consuming: own.id, now: now) }
            return .busy(ticketInfo(own.id, now: now)!)
        }
        if queuedTickets.isEmpty, freeSlots > 0 { return grant(r, consuming: nil, now: now) }
        return .busy(issueTicket(session: r.sessionId, cwd: r.cwd, now: now))
    }

    mutating func release(_ jobId: UUID, now: Date) {
        leases.removeAll { $0.jobId == jobId }
        advance(now: now)
    }

    mutating func heartbeat(_ r: JobHeartbeatRequest, now: Date) -> HeartbeatDirective {
        advance(now: now)
        guard let i = leases.firstIndex(where: { $0.jobId == r.jobId }) else { return .unknownJob }
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
        guard r.toolName == "Bash", let cmd = r.command, !CommandMatcher.isWrapped(cmd),
              CommandMatcher.matches(cmd, patterns: settings.patterns) else { return .allow }
        guard !level.isOff else { return .deny(reason: CgateMessage.gateOff) }
        let cwd = r.cwd ?? ""
        if let own = ownTicket(session: r.sessionId, cwd: cwd) {
            if held?.ticketId == own.id {
                return .wrap(newCommand: CommandMatcher.wrap(cmd, sessionId: r.sessionId, ticket: own.id))
            }
            return .deny(reason: CgateMessage.busy(ticketInfo(own.id, now: now)!))
        }
        if queuedTickets.isEmpty, freeSlots > 0 {
            return .wrap(newCommand: CommandMatcher.wrap(cmd, sessionId: r.sessionId, ticket: nil))
        }
        return .deny(reason: CgateMessage.busy(issueTicket(session: r.sessionId, cwd: cwd, now: now)))
    }

    /// Long-poll step for `waitTicket`. `ready` also clears the slot-ready notice.
    mutating func waitStatus(_ id: String, now: Date) -> WaitTicketResult {
        advance(now: now)
        if let h = held, h.ticketId == id {
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
            for i in leases.indices where leases[i].state == .stopRequested && leases[i].stopReason == .userSoftStop {
                leases[i].state = .running
                leases[i].stopReason = nil
                leases[i].stopRequestedAt = nil
            }
        }
        for i in leases.indices { applyLevel(toLeaseAt: i) }
        advance(now: now)
    }

    /// False if the job is unknown.
    mutating func killJob(_ jobId: UUID, now: Date) -> Bool {
        advance(now: now)
        guard let i = leases.firstIndex(where: { $0.jobId == jobId }) else { return false }
        if leases[i].state != .killing {
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

    /// Remove leases whose cgate pid is dead (GATE-6).
    mutating func reap(dead: Set<Int32>, now: Date) {
        leases.removeAll { dead.contains($0.pid) }
        advance(now: now)
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
