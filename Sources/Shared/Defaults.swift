import Foundation

/// All default configuration values, in one place. Durations are in seconds.
///
/// FROZEN CONTRACT (orchestrator-owned). Request changes via your status file.
public enum Defaults {
    // MARK: Gate

    /// Concurrent heavy-run slots when the gate is on (GATE-1).
    public static let slots = 2
    /// Max runtime used when `cgate run` gets no `--max` (GATE-4).
    public static let defaultMaxRuntime: TimeInterval = 15 * 60
    /// Hard cap for any declared max runtime; larger values are clamped (GATE-4).
    public static let maxRuntimeCap: TimeInterval = 60 * 60
    /// A freed slot is held this long for the oldest ticket (GATE-12).
    public static let ticketHold: TimeInterval = 2 * 60
    /// Walltime exceeded → soft notice; hard kill after this grace (GATE-5).
    public static let walltimeGrace: TimeInterval = 60
    /// Hard stop: SIGTERM process group, SIGKILL after this delay (GATE-10).
    public static let killGrace: TimeInterval = 5
    /// `cgate run` → app lease heartbeat interval.
    public static let leaseHeartbeatInterval: TimeInterval = 2
    /// App reaps leases whose pid is dead at this interval (GATE-6).
    public static let reaperInterval: TimeInterval = 5
    /// Server-side long-poll window for `waitTicket`; on timeout it answers `pending`
    /// and `cgate wait` re-polls.
    public static let waitTicketPollWindow: TimeInterval = 30
    /// Auto-wrap pattern list (AGENT-4). Each entry is a command prefix matched against
    /// the start of any `&&`/`;`/`|`-separated segment (matching semantics: GateCore).
    public static let autoWrapPatterns: [String] = [
        "pytest", "uv run pytest", "python -m pytest",
        "xcodebuild",
        "swift build", "swift test",
        "check.sh", "./scripts/check.sh", "scripts/check.sh",
        "pnpm build", "pnpm test", "pnpm run build", "pnpm run test",
        "npm run build", "npm test", "npm run test",
        "vitest", "npx vitest", "pnpm vitest",
        "playwright", "npx playwright", "pnpm playwright",
        "cargo build", "cargo test",
        "docker build",
        "make",
    ]

    // MARK: Fans

    /// App → fand heartbeat interval (FAN-5).
    public static let fanHeartbeatInterval: TimeInterval = 2
    /// fand reverts to Auto after this long without heartbeat (FAN-5).
    public static let fanWatchdogTimeout: TimeInterval = 10
    /// Performance curve (FAN-2).
    public static let fanCurve = FanCurve(lowTemp: 55, highTemp: 85, hysteresis: 3, tick: 2)
    /// fand `subscribe` push interval.
    public static let fanSubscribeInterval: TimeInterval = 2

    // MARK: IPC

    /// Max bytes of a single NDJSON line (excluding the newline). Longer lines are rejected.
    /// Sized well above worst-case `status` replies (leases × capped command, JSON escaping
    /// can inflate up to 6×, plus tickets, notices, patterns).
    public static let maxLineBytes = 4 * 1024 * 1024
    /// Sender-side cap for `AcquireRequest.command` (UTF-8 bytes, incl. truncation marker).
    public static let maxCommandBytes = 4 * 1024
    /// Max concurrent connections per server; excess connections are closed immediately.
    public static let maxConnections = 32
    /// Server-side send timeout on accepted connections: a peer that stops reading (e.g. a
    /// stalled `subscribe` client) makes writes fail with `.timeout`; the connection then ends.
    public static let serverSendTimeout: TimeInterval = 2
    /// Accept-loop back-off after a transient `accept` error (EMFILE, ECONNABORTED, …).
    public static let acceptRetryDelay: TimeInterval = 0.1
    /// Client timeout for `cgate hook` (AGENT-7: hook must be fast; on timeout fail-open).
    /// `MessageClient.call` enforces it as an overall deadline across all reads/writes.
    public static let hookClientTimeout: TimeInterval = 0.5
    /// Default client timeout for one request/response round trip (overall deadline of `call`).
    public static let clientTimeout: TimeInterval = 5
}

/// Performance fan curve parameters (FAN-2). Temperatures in °C, tick in seconds.
/// ≤ lowTemp → min RPM, linear up to max RPM at highTemp; hysteresis applies on falling temps.
public struct FanCurve: Codable, Sendable, Equatable {
    public var lowTemp: Double
    public var highTemp: Double
    public var hysteresis: Double
    public var tick: TimeInterval

    public init(lowTemp: Double, highTemp: Double, hysteresis: Double, tick: TimeInterval) {
        self.lowTemp = lowTemp
        self.highTemp = highTemp
        self.hysteresis = hysteresis
        self.tick = tick
    }
}
