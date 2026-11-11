import Foundation

// MARK: - Gate protocol (gate.sock)
//
// FROZEN CONTRACT (orchestrator-owned).
//
// | op           | caller      | request body           | reply body                         |
// |--------------|-------------|------------------------|------------------------------------|
// | `acquire`    | cgate run   | `AcquireRequest`       | `AcquireResult` (kind: granted / busy / off / ticketExpired) |
// | `release`    | cgate run   | `ReleaseRequest`       | —                                  |
// | `heartbeat`  | cgate run   | `JobHeartbeatRequest`  | `HeartbeatDirective` (kind: continue / softStop / hardStop / unknownJob) |
// | `hookCheck`  | cgate hook  | `HookCheckRequest`     | `HookDecision` (kind: allow / wrap / deny / notice) |
// | `waitTicket` | cgate wait  | `WaitTicketRequest`    | `WaitTicketResult` (kind: ready / expired / pending) |
// | `status`     | cgate status, UI | —                 | `GateStatus`                       |
// | `setGate`    | UI / debug  | `SetGateRequest`       | `GateStatus`                       |
// | `meeting`    | UI / debug  | —                      | `GateStatus` (gate → noMore; the APP also sets fans → auto via fand) |
// | `killJob`    | UI / debug  | `KillJobRequest`       | `GateStatus` (hard stop for one job: notice + kill; reason userKill, exit 78; `soft: true` → notice only, lease stopRequested/userKill, process untouched; unknown job → invalidState) |
// | `setSettings`| UI / debug  | `GateSettings`         | `GateStatus` (slots, default/cap max runtime, auto-wrap patterns) |
//
// The app hosts GateCore in-process; the UI calls the same ops in-process through
// `GateService.handle(_:)` (no socket). Over the socket they are the cgate surface
// (setGate/meeting/killJob/setSettings exposed for debugging and scripting).
//
// Size limits: `AcquireRequest.command` is capped at `Defaults.maxCommandBytes` by the sender
// (`CommandText.capped`, done by `AcquireRequest.init`); `Lease.command` in status replies may
// therefore be truncated. `HookCheckRequest.command` is NOT truncated (the server needs it
// verbatim to build `wrap`); a request over `Defaults.maxLineBytes` fails and the hook fails
// open.

// MARK: Requests

public struct AcquireRequest: Codable, Sendable, Equatable {
    /// Claude Code session id, or `unknown` (AGENT-6).
    public var sessionId: String
    public var cwd: String
    /// The wrapped command, as the user/agent wrote it; capped by `init` at
    /// `Defaults.maxCommandBytes` (`CommandText.capped`).
    public var command: String
    /// cgate's pid.
    public var pid: Int32
    /// Child pgid if already known (usually nil; sent later via heartbeat).
    public var pgid: Int32?
    /// Declared max runtime; nil → settings default. Server clamps to cap.
    public var maxRuntimeSeconds: TimeInterval?
    /// Ticket being claimed (`cgate run --ticket`).
    public var ticket: String?
    public var autoWrapped: Bool
    public var messagingSocket: String?
    /// Set when re-registering an already running job after the heartbeat answered
    /// `unknownJob` (app restarted). Always granted; see `Reattach`.
    public var reattach: Reattach?

    public init(sessionId: String, cwd: String, command: String, pid: Int32, pgid: Int32? = nil,
                maxRuntimeSeconds: TimeInterval? = nil, ticket: String? = nil,
                autoWrapped: Bool = false, messagingSocket: String? = nil,
                reattach: Reattach? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.command = CommandText.capped(command)
        self.pid = pid
        self.pgid = pgid
        self.maxRuntimeSeconds = maxRuntimeSeconds
        self.ticket = ticket
        self.autoWrapped = autoWrapped
        self.messagingSocket = messagingSocket
        self.reattach = reattach
    }
}

/// Re-registration of a running job (cgate behaviour on `unknownJob`):
/// cgate keeps the child running (never kills on `unknownJob`) and re-sends `acquire` with the
/// original fields (sessionId, cwd, command, pid, pgid, autoWrapped, messagingSocket),
/// `maxRuntimeSeconds` = the effective value from the original `granted`, `ticket` = nil, and
/// `reattach` = {original jobId, original startedAt}. The server ALWAYS answers `granted`
/// (ignores slot count and gate level; running processes are never refused), reusing `jobId`
/// and keeping `startedAt`, so the walltime deadline is unchanged. If the gate is off, the
/// usual stop directives follow on later heartbeats. If the app is unreachable, cgate keeps
/// the child running and retries at the heartbeat interval.
/// cgate records its local time when it receives `granted` and uses that as `startedAt` here.
/// cgate and the hook client retry once (after ~100 ms) on `.closed` (e.g. connection cap hit)
/// before treating the app as unreachable.
public struct Reattach: Codable, Sendable, Equatable {
    public var jobId: UUID
    public var startedAt: Date

    public init(jobId: UUID, startedAt: Date) {
        self.jobId = jobId
        self.startedAt = startedAt
    }
}

/// Why a job ended.
public enum ReleaseReason: String, Codable, Sendable {
    /// Child exited on its own (any exit code).
    case exited
    /// Killed by cgate after a hardStop directive.
    case killed
    /// Child could not be spawned. cgate exits `CgateExit.spawnFailed` (70).
    case spawnFailed
    /// cgate itself got a signal (e.g. Ctrl-C) and forwarded it. cgate exits
    /// `CgateExit.interrupted` (130).
    case interrupted
}

public struct ReleaseRequest: Codable, Sendable, Equatable {
    public var jobId: UUID
    public var exitCode: Int32?
    public var reason: ReleaseReason

    public init(jobId: UUID, exitCode: Int32?, reason: ReleaseReason) {
        self.jobId = jobId
        self.exitCode = exitCode
        self.reason = reason
    }
}

public struct JobHeartbeatRequest: Codable, Sendable, Equatable {
    public var jobId: UUID
    /// Child pgid once spawned (first heartbeat after spawn must include it).
    public var pgid: Int32?

    public init(jobId: UUID, pgid: Int32? = nil) {
        self.jobId = jobId
        self.pgid = pgid
    }
}

public struct HookCheckRequest: Codable, Sendable, Equatable {
    public var sessionId: String
    /// Claude Code tool name, e.g. `Bash`.
    public var toolName: String
    /// `tool_input.command` for Bash; nil otherwise.
    public var command: String?
    public var cwd: String?

    public init(sessionId: String, toolName: String, command: String? = nil, cwd: String? = nil) {
        self.sessionId = sessionId
        self.toolName = toolName
        self.command = command
        self.cwd = cwd
    }
}

public struct WaitTicketRequest: Codable, Sendable, Equatable {
    public var ticket: String
    public init(ticket: String) { self.ticket = ticket }
}

public struct SetGateRequest: Codable, Sendable, Equatable {
    public var level: GateLevel
    /// New configured slot count; nil keeps current.
    public var slots: Int?

    public init(level: GateLevel, slots: Int? = nil) {
        self.level = level
        self.slots = slots
    }
}

public struct KillJobRequest: Codable, Sendable, Equatable {
    public var jobId: UUID
    /// true → soft stop of this job only (notice, no signal). nil/false → hard kill (old behaviour).
    public var soft: Bool?
    public init(jobId: UUID, soft: Bool? = nil) {
        self.jobId = jobId
        self.soft = soft
    }
}

public enum GateRequest: OpMessage {
    case acquire(AcquireRequest)
    case release(ReleaseRequest)
    case heartbeat(JobHeartbeatRequest)
    case hookCheck(HookCheckRequest)
    case waitTicket(WaitTicketRequest)
    case status
    case setGate(SetGateRequest)
    case meeting
    case killJob(KillJobRequest)
    case setSettings(GateSettings)

    public static var version: Int { ProtocolVersion.gate }

    public var op: String {
        switch self {
        case .acquire: "acquire"
        case .release: "release"
        case .heartbeat: "heartbeat"
        case .hookCheck: "hookCheck"
        case .waitTicket: "waitTicket"
        case .status: "status"
        case .setGate: "setGate"
        case .meeting: "meeting"
        case .killJob: "killJob"
        case .setSettings: "setSettings"
        }
    }

    public func encodeBody(into c: inout KeyedEncodingContainer<EnvelopeKey>) throws {
        switch self {
        case .acquire(let b): try c.encode(b, forKey: .body)
        case .killJob(let b): try c.encode(b, forKey: .body)
        case .setSettings(let b): try c.encode(b, forKey: .body)
        case .release(let b): try c.encode(b, forKey: .body)
        case .heartbeat(let b): try c.encode(b, forKey: .body)
        case .hookCheck(let b): try c.encode(b, forKey: .body)
        case .waitTicket(let b): try c.encode(b, forKey: .body)
        case .setGate(let b): try c.encode(b, forKey: .body)
        case .status, .meeting: break
        }
    }

    public init(op: String, from c: KeyedDecodingContainer<EnvelopeKey>) throws {
        switch op {
        case "acquire": self = .acquire(try c.body(AcquireRequest.self))
        case "release": self = .release(try c.body(ReleaseRequest.self))
        case "heartbeat": self = .heartbeat(try c.body(JobHeartbeatRequest.self))
        case "hookCheck": self = .hookCheck(try c.body(HookCheckRequest.self))
        case "waitTicket": self = .waitTicket(try c.body(WaitTicketRequest.self))
        case "status": self = .status
        case "setGate": self = .setGate(try c.body(SetGateRequest.self))
        case "meeting": self = .meeting
        case "killJob": self = .killJob(try c.body(KillJobRequest.self))
        case "setSettings": self = .setSettings(try c.body(GateSettings.self))
        default: throw WireError(.unknownOp, op)
        }
    }
}

// MARK: Reply bodies (discriminated by "kind")

/// Result of `acquire`.
public enum AcquireResult: Codable, Sendable, Equatable {
    /// Slot granted. `maxRuntimeSeconds` is the effective (defaulted + capped) value.
    case granted(jobId: UUID, maxRuntimeSeconds: TimeInterval)
    /// No slot: ticket issued (or the existing ticket of this (session, cwd)); also the answer
    /// to `run --ticket` whose ticket is still queued (current position/ETA, ticket kept).
    /// cgate exits 75. Never returned for `reattach`.
    case busy(TicketInfo)
    /// Gate off. cgate exits 76 with `message` (= `CgateMessage.gateOff`). Never for `reattach`.
    case off(message: String)
    /// The claimed ticket is unknown or expired. cgate exits 79.
    case ticketExpired(ticket: String)

    private enum K: String, CodingKey { case jobId, maxRuntimeSeconds, message, ticket }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try decoder.decodeKind() {
        case "granted":
            self = .granted(jobId: try c.decode(UUID.self, forKey: .jobId),
                            maxRuntimeSeconds: try c.decode(TimeInterval.self, forKey: .maxRuntimeSeconds))
        case "busy": self = .busy(try TicketInfo(from: decoder))
        case "off": self = .off(message: try c.decode(String.self, forKey: .message))
        case "ticketExpired": self = .ticketExpired(ticket: try c.decode(String.self, forKey: .ticket))
        case let k: throw WireError(.badRequest, "unknown AcquireResult kind \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .granted(let id, let max):
            try c.encode(id, forKey: .jobId)
            try c.encode(max, forKey: .maxRuntimeSeconds)
            try encoder.encodeKind("granted", Empty?.none)
        case .busy(let t): try encoder.encodeKind("busy", t)
        case .off(let m):
            try c.encode(m, forKey: .message)
            try encoder.encodeKind("off", Empty?.none)
        case .ticketExpired(let t):
            try c.encode(t, forKey: .ticket)
            try encoder.encodeKind("ticketExpired", Empty?.none)
        }
    }
}

/// Answer to a job `heartbeat`.
public enum HeartbeatDirective: Codable, Sendable, Equatable {
    case `continue`
    /// Notice-only stop request (walltime reached / soft stop). Process is NOT signalled.
    case softStop(reason: StopReason)
    /// cgate must SIGTERM the child pgid, SIGKILL after `Defaults.killGrace`, then exit
    /// 77 (walltime) or 78 (user).
    case hardStop(reason: StopReason)
    /// App does not know this job (e.g. app restarted). cgate re-sends `acquire` with
    /// `reattach` (see `Reattach`) and continues heartbeating with the returned jobId;
    /// it never kills on `unknownJob`.
    case unknownJob

    private enum K: String, CodingKey { case reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try decoder.decodeKind() {
        case "continue": self = .continue
        case "softStop": self = .softStop(reason: try c.decode(StopReason.self, forKey: .reason))
        case "hardStop": self = .hardStop(reason: try c.decode(StopReason.self, forKey: .reason))
        case "unknownJob": self = .unknownJob
        case let k: throw WireError(.badRequest, "unknown HeartbeatDirective kind \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .continue: try encoder.encodeKind("continue", Empty?.none)
        case .softStop(let r):
            try c.encode(r, forKey: .reason)
            try encoder.encodeKind("softStop", Empty?.none)
        case .hardStop(let r):
            try c.encode(r, forKey: .reason)
            try encoder.encodeKind("hardStop", Empty?.none)
        case .unknownJob: try encoder.encodeKind("unknownJob", Empty?.none)
        }
    }
}

/// Answer to `hookCheck`; cgate hook maps it to Claude Code hook JSON.
public enum HookDecision: Codable, Sendable, Equatable {
    /// No output; tool call proceeds unchanged.
    case allow
    /// `permissionDecision: allow` + `updatedInput.command = newCommand` (other fields preserved).
    case wrap(newCommand: String)
    /// `permissionDecision: deny` with reason (busy / off text).
    case deny(reason: String)
    /// Pending notice: `permissionDecision: deny` once with the notice text; server clears it.
    case notice(text: String)

    private enum K: String, CodingKey { case newCommand, reason, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try decoder.decodeKind() {
        case "allow": self = .allow
        case "wrap": self = .wrap(newCommand: try c.decode(String.self, forKey: .newCommand))
        case "deny": self = .deny(reason: try c.decode(String.self, forKey: .reason))
        case "notice": self = .notice(text: try c.decode(String.self, forKey: .text))
        case let k: throw WireError(.badRequest, "unknown HookDecision kind \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .allow: try encoder.encodeKind("allow", Empty?.none)
        case .wrap(let n):
            try c.encode(n, forKey: .newCommand)
            try encoder.encodeKind("wrap", Empty?.none)
        case .deny(let r):
            try c.encode(r, forKey: .reason)
            try encoder.encodeKind("deny", Empty?.none)
        case .notice(let t):
            try c.encode(t, forKey: .text)
            try encoder.encodeKind("notice", Empty?.none)
        }
    }
}

/// Answer to `waitTicket` (long-poll up to `Defaults.waitTicketPollWindow`).
public enum WaitTicketResult: Codable, Sendable, Equatable {
    /// Slot held for this ticket until `heldUntil`. cgate wait exits 0.
    case ready(ticket: String, heldUntil: Date)
    /// Ticket unknown/expired. cgate wait exits 79.
    case expired(ticket: String)
    /// Poll window elapsed, still queued; cgate wait re-polls.
    case pending(TicketInfo)

    private enum K: String, CodingKey { case ticket, heldUntil }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try decoder.decodeKind() {
        case "ready":
            self = .ready(ticket: try c.decode(String.self, forKey: .ticket),
                          heldUntil: try c.decode(Date.self, forKey: .heldUntil))
        case "expired": self = .expired(ticket: try c.decode(String.self, forKey: .ticket))
        case "pending": self = .pending(try TicketInfo(from: decoder))
        case let k: throw WireError(.badRequest, "unknown WaitTicketResult kind \(k)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case .ready(let t, let u):
            try c.encode(t, forKey: .ticket)
            try c.encode(u, forKey: .heldUntil)
            try encoder.encodeKind("ready", Empty?.none)
        case .expired(let t):
            try c.encode(t, forKey: .ticket)
            try encoder.encodeKind("expired", Empty?.none)
        case .pending(let i): try encoder.encodeKind("pending", i)
        }
    }
}

public enum GateReply: OpMessage {
    case acquire(AcquireResult)
    case release
    case heartbeat(HeartbeatDirective)
    case hookCheck(HookDecision)
    case waitTicket(WaitTicketResult)
    case status(GateStatus)
    case setGate(GateStatus)
    case meeting(GateStatus)
    case killJob(GateStatus)
    case setSettings(GateStatus)

    public static var version: Int { ProtocolVersion.gate }

    public var op: String {
        switch self {
        case .acquire: "acquire"
        case .release: "release"
        case .heartbeat: "heartbeat"
        case .hookCheck: "hookCheck"
        case .waitTicket: "waitTicket"
        case .status: "status"
        case .setGate: "setGate"
        case .meeting: "meeting"
        case .killJob: "killJob"
        case .setSettings: "setSettings"
        }
    }

    public func encodeBody(into c: inout KeyedEncodingContainer<EnvelopeKey>) throws {
        switch self {
        case .acquire(let b): try c.encode(b, forKey: .body)
        case .release: break
        case .heartbeat(let b): try c.encode(b, forKey: .body)
        case .hookCheck(let b): try c.encode(b, forKey: .body)
        case .waitTicket(let b): try c.encode(b, forKey: .body)
        case .status(let b), .setGate(let b), .meeting(let b), .killJob(let b), .setSettings(let b):
            try c.encode(b, forKey: .body)
        }
    }

    public init(op: String, from c: KeyedDecodingContainer<EnvelopeKey>) throws {
        switch op {
        case "acquire": self = .acquire(try c.body(AcquireResult.self))
        case "release": self = .release
        case "heartbeat": self = .heartbeat(try c.body(HeartbeatDirective.self))
        case "hookCheck": self = .hookCheck(try c.body(HookDecision.self))
        case "waitTicket": self = .waitTicket(try c.body(WaitTicketResult.self))
        case "status": self = .status(try c.body(GateStatus.self))
        case "setGate": self = .setGate(try c.body(GateStatus.self))
        case "meeting": self = .meeting(try c.body(GateStatus.self))
        case "killJob": self = .killJob(try c.body(GateStatus.self))
        case "setSettings": self = .setSettings(try c.body(GateStatus.self))
        default: throw WireError(.unknownOp, op)
        }
    }
}

public typealias GateRequestEnvelope = Request<GateRequest>
public typealias GateResponseEnvelope = Response<GateReply>
