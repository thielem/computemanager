import Foundation
import Shared

/// `cgate hook`: Claude Code PreToolUse hook (AGENT-2/3/5/7).
///
/// stdin: hook JSON (`session_id`, `cwd`, `tool_name`, `tool_input`). Asks the gate
/// (`hookCheck`, overall ≤ `Defaults.hookClientTimeout`) and maps the decision:
/// - `wrap`   → allow + `updatedInput` = original `tool_input` with `command` replaced
/// - `deny`   → deny with the busy / gate-off text
/// - `notice` → deny once with the notice text
/// - `allow`, app unreachable, bad input → no output (fail open). Always exit 0.
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
        return render(decision, toolInput: toolInput)
    }

    static func render(_ d: HookDecision, toolInput: [String: Any]) -> Data? {
        var out: [String: Any] = ["hookEventName": "PreToolUse"]
        switch d {
        case .allow:
            return nil
        case .wrap(let cmd):
            var updated = toolInput
            updated["command"] = cmd
            out["permissionDecision"] = "allow"
            out["updatedInput"] = updated
        case .deny(let reason), .notice(let reason):
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = reason
        }
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": out],
                                           options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
