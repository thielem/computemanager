import Foundation

// MARK: - fand protocol (fand.sock)
//
// FROZEN CONTRACT (orchestrator-owned).
//
// | op          | request body          | reply body                                   |
// |-------------|-----------------------|----------------------------------------------|
// | `status`    | —                     | `FanStatus`                                  |
// | `setMode`   | `{"mode":"performance","curve":{…}?}` | `FanStatus` (after applying) |
// | `heartbeat` | —                     | — (resets the watchdog, FAN-5)               |
// | `subscribe` | —                     | stream of `FanStatus`, every `Defaults.fanSubscribeInterval`, same `id`, op `subscribe` |
//
// `setMode.curve` (optional, additive): performance curve. fand clamps it (`FanCurve.clamped`,
// tick stays fand's), rejects non-finite values with `badRequest` (nothing changes), and keeps
// it in memory only (Defaults after a fand restart). The app persists the curve and sends it
// with every `setMode`. Older fands ignore the field.
//
// Auth: every connection's peer UID must equal the console user's UID, else the first request
// is answered with `unauthorized` and the connection is closed (FAN-9). No raw SMC access
// over IPC.
//
// Safety (FAN-4/FAN-5), three layers:
//   1. Clean quit: the app sends `setMode(auto)` before exiting.
//   2. Crash: fand registers `MessageServer(onDisconnect:)`; when a connection that sent
//      `setMode`/`heartbeat` (the app's control connection, identified by
//      `RequestContext.connectionId`) drops, fand reverts to Auto immediately.
//   3. Watchdog: no `heartbeat` for `Defaults.fanWatchdogTimeout` (10 s) → Auto (last resort).
// After reconnecting the control connection, the app re-sends its current `setMode` (fand
// reverted to Auto when the old connection dropped).
// The app uses separate connections: one for `subscribe` (blocked by the stream) and one for
// `heartbeat`/`setMode`/`status` requests (the control connection).

/// User-selectable fan mode (FAN-1).
public enum FanMode: String, Codable, Sendable, CaseIterable {
    /// Apple's default control (`F*Md=0`; `Ftst=0` only if the key exists; absent on
    /// M2 Pro / macOS 27).
    case auto
    /// Custom curve on hottest P-core temperature (FAN-2, FAN-3).
    case performance
    /// All fans at max RPM.
    case max
}

/// Per-fan hardware control mode as read from the SMC (`F{n}Md`).
public enum FanControl: String, Codable, Sendable {
    /// `F{n}Md = 0`: system controlled.
    case auto
    /// `F{n}Md = 1`: forced target (`F{n}Tg`).
    case manual
}

/// Mirrors `ProcessInfo.ThermalState`.
public enum ThermalState: String, Codable, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// One fan (FAN-8).
public struct FanInfo: Codable, Sendable, Equatable, Identifiable {
    /// SMC fan index (0-based, `F{id}Ac` etc.).
    public var id: Int
    public var actualRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    /// Current target (`F{n}Tg`); nil if unreadable.
    public var targetRPM: Double?
    public var control: FanControl

    public init(id: Int, actualRPM: Double, minRPM: Double, maxRPM: Double,
                targetRPM: Double?, control: FanControl) {
        self.id = id
        self.actualRPM = actualRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.targetRPM = targetRPM
        self.control = control
    }
}

/// Key temperatures in °C; nil when the sensor set is unavailable.
public struct Temperatures: Codable, Sendable, Equatable {
    public var pcoreMax: Double?
    public var ecoreMax: Double?
    public var gpuMax: Double?

    public init(pcoreMax: Double? = nil, ecoreMax: Double? = nil, gpuMax: Double? = nil) {
        self.pcoreMax = pcoreMax
        self.ecoreMax = ecoreMax
        self.gpuMax = gpuMax
    }
}

/// fand status snapshot.
public struct FanStatus: Codable, Sendable, Equatable {
    public var mode: FanMode
    public var fans: [FanInfo]
    public var temps: Temperatures
    public var thermalState: ThermalState
    /// Last heartbeat received from the app; nil if none since start.
    public var lastHeartbeat: Date?
    public var curve: FanCurve

    public init(mode: FanMode, fans: [FanInfo], temps: Temperatures, thermalState: ThermalState,
                lastHeartbeat: Date?, curve: FanCurve = Defaults.fanCurve) {
        self.mode = mode
        self.fans = fans
        self.temps = temps
        self.thermalState = thermalState
        self.lastHeartbeat = lastHeartbeat
        self.curve = curve
    }
}

public struct SetModeRequest: Codable, Sendable, Equatable {
    public var mode: FanMode
    /// Performance curve; nil = keep fand's current one.
    public var curve: FanCurve?
    public init(mode: FanMode, curve: FanCurve? = nil) {
        self.mode = mode
        self.curve = curve
    }
}

/// Requests to fand.
public enum FanRequest: OpMessage {
    case status
    case setMode(SetModeRequest)
    case heartbeat
    case subscribe

    public static var version: Int { ProtocolVersion.fand }

    public var op: String {
        switch self {
        case .status: "status"
        case .setMode: "setMode"
        case .heartbeat: "heartbeat"
        case .subscribe: "subscribe"
        }
    }

    public func encodeBody(into c: inout KeyedEncodingContainer<EnvelopeKey>) throws {
        if case .setMode(let b) = self { try c.encode(b, forKey: .body) }
    }

    public init(op: String, from c: KeyedDecodingContainer<EnvelopeKey>) throws {
        switch op {
        case "status": self = .status
        case "setMode": self = .setMode(try c.body(SetModeRequest.self))
        case "heartbeat": self = .heartbeat
        case "subscribe": self = .subscribe
        default: throw WireError(.unknownOp, op)
        }
    }
}

/// Replies from fand. Case names equal the request op.
public enum FanReply: OpMessage {
    case status(FanStatus)
    case setMode(FanStatus)
    case heartbeat
    /// One pushed item of a `subscribe` stream.
    case subscribe(FanStatus)

    public static var version: Int { ProtocolVersion.fand }

    public var op: String {
        switch self {
        case .status: "status"
        case .setMode: "setMode"
        case .heartbeat: "heartbeat"
        case .subscribe: "subscribe"
        }
    }

    public func encodeBody(into c: inout KeyedEncodingContainer<EnvelopeKey>) throws {
        switch self {
        case .status(let s), .setMode(let s), .subscribe(let s): try c.encode(s, forKey: .body)
        case .heartbeat: break
        }
    }

    public init(op: String, from c: KeyedDecodingContainer<EnvelopeKey>) throws {
        switch op {
        case "status": self = .status(try c.body(FanStatus.self))
        case "setMode": self = .setMode(try c.body(FanStatus.self))
        case "heartbeat": self = .heartbeat
        case "subscribe": self = .subscribe(try c.body(FanStatus.self))
        default: throw WireError(.unknownOp, op)
        }
    }
}

public typealias FanRequestEnvelope = Request<FanRequest>
public typealias FanResponseEnvelope = Response<FanReply>
