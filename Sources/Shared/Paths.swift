import Foundation

/// Filesystem locations shared by all binaries.
///
/// FROZEN CONTRACT (orchestrator-owned). Env overrides exist for tests and E2E only.
public enum Paths {
    /// Env var overriding the fand socket path.
    public static let fandSocketEnv = "COMPUTEMANAGER_FAND_SOCK"
    /// Env var overriding the gate socket path.
    public static let gateSocketEnv = "COMPUTEMANAGER_GATE_SOCK"

    /// Root-owned directory (0755) holding the fand socket.
    public static let fandSocketDirectory = "/var/run/computemanager"
    /// fand socket. Owner root; access restricted by peer UID check (FAN-9).
    public static let defaultFandSocket = "/var/run/computemanager/fand.sock"

    /// Per-user app support directory.
    public static var appSupportDirectory: String {
        home + "/Library/Application Support/ComputeManager"
    }

    /// Gate socket (mode 0600), served by the app (GateCore).
    public static var defaultGateSocket: String { appSupportDirectory + "/gate.sock" }

    /// Log directory.
    public static var logDirectory: String { home + "/Library/Logs/ComputeManager" }

    /// cgate appends here when the app is unreachable (GATE-11).
    public static var cgateFallbackLog: String { logDirectory + "/cgate-fallback.log" }

    /// Effective fand socket path (env override or default).
    public static var fandSocket: String {
        ProcessInfo.processInfo.environment[fandSocketEnv] ?? defaultFandSocket
    }

    /// Effective gate socket path (env override or default).
    public static var gateSocket: String {
        ProcessInfo.processInfo.environment[gateSocketEnv] ?? defaultGateSocket
    }

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
}

/// Claude Code messaging socket (secondary notice channel, AGENT-10; verified in M0b).
/// Socket: `/tmp/cc-socks/<claude-pid>.sock`. NDJSON, first line
/// `{"type":"auth","token":"<token>"}`, then `{"type":"user","message":{"role":"user","content":"<text>"}}`.
/// Reaches idle sessions too. Never log the token.
public enum ClaudeMessaging {
    public static let socketEnv = "CLAUDE_CODE_MESSAGING_SOCKET"
    public static let tokenEnv = "CLAUDE_CODE_MESSAGING_TOKEN"
}

/// Identifiers used by packaging and the plugin.
public enum Identifiers {
    public static let appBundleID = "com.computemanager.app"
    public static let fandLabel = "com.computemanager.fand"
    public static let pluginName = "compute-gate"
}
