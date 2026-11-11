import Foundation

// MARK: - Gate data model
//
// FROZEN CONTRACT (orchestrator-owned). Semantics (PLAN §2 GATE, §5, §6):
//
// Levels
//   on        gate on, `slots` concurrent heavy runs.
//   noMore    effective slots = 0; running jobs finish; new acquires → `off` (GATE-8).
//   softStop  noMore + stop notice queued for every session with running jobs; NO signals (GATE-9).
//   hardStop  noMore + notice + SIGTERM process group, SIGKILL after `Defaults.killGrace` (GATE-10).
//   Leaving the gate "off" means going back to `on`.
//
// Walltime (GATE-5): at started_at + maxRuntime → lease `stopRequested` (reason walltime),
//   notice to the job's session; at + `settings.walltimeGraceSeconds` (default
//   `Defaults.walltimeGrace`; a change also moves kills already in grace) → heartbeat answers
//   `hardStop(walltime)`; cgate kills its pgid and exits 77.
//
// Tickets (GATE-12): FIFO, keyed per (sessionId, cwd). A busy acquire issues a ticket (or
//   returns the existing ticket of that (session, cwd)). Session `unknown` never shares: every
//   busy acquire from it gets its own ticket. When a slot frees and tickets exist, it is held
//   for the oldest ticket for `settings.ticketHoldSeconds` (new holds); only an acquire carrying that ticket can
//   take it. Unclaimed → ticket expires, slot goes to the next ticket (or free).
//   `run --ticket` with a ticket that is still queued (not yet held) → `busy` with the current
//   position/ETA; the ticket is kept. ETA (GATE-3) = min over running leases of
//   started_at + maxRuntime.
//
// Reattach (app restart): heartbeat answers `unknownJob` → cgate re-sends `acquire` with
//   `reattach` (see `AcquireRequest.reattach`). The server ALWAYS grants a reattach (even above
//   the slot count or with the gate off: running processes are never refused), keeps the jobId
//   and the original startedAt, so the walltime deadline is unchanged. Gate level then applies
//   via heartbeat directives as for any running lease.
//
// Command text: `Lease.command` may be truncated (senders cap it at `Defaults.maxCommandBytes`,
//   see `CommandText.capped`).

/// Gate level selected by the user.
public enum GateLevel: String, Codable, Sendable, CaseIterable {
    case on
    case noMore
    case softStop
    case hardStop

    /// True for every level except `on`.
    public var isOff: Bool { self != .on }
}

/// Lifecycle of a lease.
public enum LeaseState: String, Codable, Sendable {
    case running
    /// Soft stop or walltime reached; notice sent, process untouched.
    case stopRequested
    /// Hard stop / walltime + grace / UI kill: cgate told to kill.
    case killing
    case done
}

/// Why a job was asked to stop.
public enum StopReason: String, Codable, Sendable {
    /// Declared max runtime exceeded (exit 77 when killed).
    case walltime
    /// Gate soft stop by user.
    case userSoftStop
    /// Gate hard stop by user (exit 78).
    case userHardStop
    /// Per-job stop from the UI: soft (`stopRequested`, notice only) or kill (exit 78).
    case userKill
}

/// Registry record of a heavy run holding a slot (PLAN §5).
public struct Lease: Codable, Sendable, Equatable, Identifiable {
    public var jobId: UUID
    /// `unknown` if absent (AGENT-6).
    public var sessionId: String
    public var cwd: String
    /// May be truncated (`CommandText.capped`).
    public var command: String
    /// cgate's own pid (liveness check for reaping, GATE-6).
    public var pid: Int32
    /// Process group of the spawned child (kill target); nil until cgate reports it
    /// (cgate spawns the child after `granted`, then sends pgid with its first heartbeat).
    public var pgid: Int32?
    public var startedAt: Date
    /// Effective max runtime after default + cap (seconds).
    public var maxRuntimeSeconds: TimeInterval
    /// Wrapped by the hook (true) vs explicit `cgate run` (false).
    public var autoWrapped: Bool
    /// `CLAUDE_CODE_MESSAGING_SOCKET` if present (AGENT-10).
    public var messagingSocket: String?
    public var state: LeaseState
    public var stopRequestedAt: Date?
    public var stopReason: StopReason?
    /// Claude Code subagent that started the job (hook `agent_id`); nil = main session/unknown.
    public var agentId: String?
    /// From `AcquireRequest.label` (git folder + branch); nil from older cgate.
    public var label: String?

    public var id: UUID { jobId }
    /// Project name = last path component of cwd.
    public var project: String { (cwd as NSString).lastPathComponent }
    /// What the UI shows: `label`, else `project`.
    public var displayName: String { label ?? project }
    /// started_at + max runtime.
    public var deadline: Date { startedAt.addingTimeInterval(maxRuntimeSeconds) }

    public init(jobId: UUID = UUID(), sessionId: String, cwd: String, command: String,
                pid: Int32, pgid: Int32?, startedAt: Date, maxRuntimeSeconds: TimeInterval,
                autoWrapped: Bool, messagingSocket: String? = nil, state: LeaseState = .running,
                stopRequestedAt: Date? = nil, stopReason: StopReason? = nil, agentId: String? = nil,
                label: String? = nil) {
        self.jobId = jobId
        self.sessionId = sessionId
        self.cwd = cwd
        self.command = command
        self.pid = pid
        self.pgid = pgid
        self.startedAt = startedAt
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.autoWrapped = autoWrapped
        self.messagingSocket = messagingSocket
        self.state = state
        self.stopRequestedAt = stopRequestedAt
        self.stopReason = stopReason
        self.agentId = agentId
        self.label = label
    }
}

/// FIFO ticket record.
public struct Ticket: Codable, Sendable, Equatable, Identifiable {
    /// Short human-typable id, e.g. `t7` (GateCore chooses the format).
    public var id: String
    public var sessionId: String
    /// Tickets are keyed per (sessionId, agentId, cwd).
    public var cwd: String
    public var issuedAt: Date
    /// Subagent owning the ticket; nil = main session/unknown.
    public var agentId: String?

    public init(id: String, sessionId: String, cwd: String, issuedAt: Date, agentId: String? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.issuedAt = issuedAt
        self.agentId = agentId
    }
}

/// Ticket as reported to a caller: position is 1-based in the FIFO.
public struct TicketInfo: Codable, Sendable, Equatable {
    public var id: String
    public var position: Int
    /// Expected time of next free slot; nil if unknown (e.g. gate has no running leases).
    public var eta: Date?
    /// Hold duration once the slot is ready (nil from older apps → `Defaults.ticketHold`).
    public var holdSeconds: TimeInterval?

    public init(id: String, position: Int, eta: Date?, holdSeconds: TimeInterval? = nil) {
        self.id = id
        self.position = position
        self.eta = eta
        self.holdSeconds = holdSeconds
    }
}

/// A freed slot reserved for a ticket.
public struct HeldSlot: Codable, Sendable, Equatable {
    public var ticketId: String
    public var until: Date

    public init(ticketId: String, until: Date) {
        self.ticketId = ticketId
        self.until = until
    }
}

/// One undelivered notice for a session (delivered once by `hookCheck`).
public struct PendingNotice: Codable, Sendable, Equatable {
    public var sessionId: String
    public var text: String

    public init(sessionId: String, text: String) {
        self.sessionId = sessionId
        self.text = text
    }
}

/// User-editable gate settings (persisted by the app; changed via `setSettings`).
public struct GateSettings: Codable, Sendable, Equatable {
    /// Configured slot count (same value as `GateStatus.slots`; `setGate` with `slots` updates it).
    public var slots: Int
    /// Auto-wrap patterns (AGENT-4).
    public var patterns: [String]
    public var defaultMaxRuntimeSeconds: TimeInterval
    public var maxRuntimeCapSeconds: TimeInterval
    /// How long a freed slot is held for the oldest ticket (applies to new holds).
    public var ticketHoldSeconds: TimeInterval
    /// Walltime soft notice → hard kill delay.
    public var walltimeGraceSeconds: TimeInterval

    public init(slots: Int = Defaults.slots,
                patterns: [String] = Defaults.autoWrapPatterns,
                defaultMaxRuntimeSeconds: TimeInterval = Defaults.defaultMaxRuntime,
                maxRuntimeCapSeconds: TimeInterval = Defaults.maxRuntimeCap,
                ticketHoldSeconds: TimeInterval = Defaults.ticketHold,
                walltimeGraceSeconds: TimeInterval = Defaults.walltimeGrace) {
        self.slots = slots
        self.patterns = patterns
        self.defaultMaxRuntimeSeconds = defaultMaxRuntimeSeconds
        self.maxRuntimeCapSeconds = maxRuntimeCapSeconds
        self.ticketHoldSeconds = ticketHoldSeconds
        self.walltimeGraceSeconds = walltimeGraceSeconds
    }

    /// Hold and grace are optional on the wire (older gate.json / peers lack them).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode(Int.self, forKey: .slots)
        patterns = try c.decode([String].self, forKey: .patterns)
        defaultMaxRuntimeSeconds = try c.decode(TimeInterval.self, forKey: .defaultMaxRuntimeSeconds)
        maxRuntimeCapSeconds = try c.decode(TimeInterval.self, forKey: .maxRuntimeCapSeconds)
        ticketHoldSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .ticketHoldSeconds) ?? Defaults.ticketHold
        walltimeGraceSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .walltimeGraceSeconds)
            ?? Defaults.walltimeGrace
    }
}

/// Snapshot of the gate, returned by `status`, `setGate`, `meeting`.
public struct GateStatus: Codable, Sendable, Equatable {
    public var level: GateLevel
    /// Configured slots (kept while off, restored on `on`).
    public var slots: Int
    /// 0 when off, else `slots`.
    public var effectiveSlots: Int
    public var leases: [Lease]
    /// FIFO order, with derived positions/ETA.
    public var tickets: [TicketInfo]
    public var heldSlot: HeldSlot?
    /// ETA of next free slot (GATE-3); nil if no running leases.
    public var nextSlotETA: Date?
    public var pendingNotices: [PendingNotice]
    public var settings: GateSettings

    public init(level: GateLevel, slots: Int, effectiveSlots: Int, leases: [Lease],
                tickets: [TicketInfo], heldSlot: HeldSlot?, nextSlotETA: Date?,
                pendingNotices: [PendingNotice], settings: GateSettings) {
        self.level = level
        self.slots = slots
        self.effectiveSlots = effectiveSlots
        self.leases = leases
        self.tickets = tickets
        self.heldSlot = heldSlot
        self.nextSlotETA = nextSlotETA
        self.pendingNotices = pendingNotices
        self.settings = settings
    }
}
