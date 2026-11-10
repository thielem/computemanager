import Foundation
import Shared

/// `cgate hook`: Claude Code PreToolUse hook (AGENT-2/3/5/7).
///
/// stdin: hook JSON (`session_id`, `cwd`, `tool_name`, `tool_input`). Asks the gate
/// (`hookCheck`, overall ≤ `Defaults.hookClientTimeout`) and maps the decision:
/// - `deny`   → deny with the reason (heavy command not run via cgate: the exact
///              `cgate run --max <estimate> -- '<cmd>'` line to use instead)
/// - `notice` → deny once with the notice text (stop / slot ready)
/// - `allow`, app unreachable, bad input → no output (fail open). Always exit 0.
/// The hook never rewrites commands and never answers "allow" (K1, user decision); a legacy
/// `wrap` decision is ignored (no output).
enum Hook {
    static func output(stdin: Data, link: GateLink, timeout: TimeInterval = Defaults.hookClientTimeout) -> Data? {
        guard let input = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let tool = input["tool_name"] as? String else { return nil }
        let toolInput = input["tool_input"] as? [String: Any] ?? [:]
        let req = HookCheckRequest(
            sessionId: (input["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown",
            toolName: tool,
            command: toolInput["command"] as? String,
            cwd: input["cwd"] as? String)
        guard case .hookCheck(let decision)? = try? link.call(.hookCheck(req), timeout: timeout) else { return nil }
        return render(decision)
    }

    static func render(_ d: HookDecision) -> Data? {
        var out: [String: Any] = ["hookEventName": "PreToolUse"]
        switch d {
        case .allow, .wrap:
            return nil
        case .deny(let reason), .notice(let reason):
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = reason
        }
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": out],
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
