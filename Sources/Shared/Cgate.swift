import Foundation

// MARK: - cgate exit codes and user-facing messages
//
// FROZEN CONTRACT (orchestrator-owned). PLAN §4 "cgate exit codes + output".
// Messages go to stderr as one line. Agents parse nothing but exit codes; the text is for
// the agent to read and act on, so wording matters.

public enum CgateExit {
    /// `cgate wait`: slot ready.
    public static let ok: Int32 = 0
    /// Usage error.
    public static let usage: Int32 = 64
    /// No slot; ticket issued.
    public static let busy: Int32 = 75
    /// Gate off (noMore / softStop / hardStop).
    public static let gateOff: Int32 = 76
    /// Killed after exceeding declared max runtime (+ grace).
    public static let walltimeKill: Int32 = 77
    /// Killed by user (hard stop / UI kill).
    public static let stoppedByUser: Int32 = 78
    /// Ticket expired / unknown (`wait`, `run --ticket`).
    public static let ticketExpired: Int32 = 79
    // `cgate run` otherwise exits with the child's exit code (128 + signal if signalled).

    /// Exit code for a hard stop directive.
    public static func forHardStop(_ reason: StopReason) -> Int32 {
        reason == .walltime ? walltimeKill : stoppedByUser
    }
}

public enum CgateMessage {
    /// Exit 76; also the `off` text in `acquire` and the hook deny reason.
    public static let gateOff = "Compute gate off — continue without heavy runs or stop and report"

    /// Exit 75; also the hook deny reason when busy.
    public static func busy(_ t: TicketInfo) -> String {
        "compute busy: ticket \(t.id), position \(t.position), next slot ~\(clock(t.eta)). "
            + "Run in background: cgate wait --ticket \(t.id); do other work meanwhile"
    }

    /// Exit 77.
    public static func walltimeKilled(max: TimeInterval) -> String {
        "killed: exceeded declared max runtime (\(DurationFormat.format(max)))"
    }

    /// Exit 78.
    public static let stoppedByUser = "killed by user: hard stop"

    /// Exit 79.
    public static func ticketExpired(_ id: String) -> String {
        "ticket \(id) expired; retry cgate run"
    }

    /// `cgate wait` exit 0, and the "slot ready" notice text (literal `--max ... -- <cmd>`).
    public static func slotReady(ticket: String, heldUntil: Date) -> String {
        "slot ready (ticket \(ticket), held until \(clock(heldUntil))): "
            + "cgate run --ticket \(ticket) --max ... -- <cmd>"
    }

    // MARK: Stop notices (delivered once via the `"*"` hook, AGENT-5)

    /// Walltime reached (soft step of GATE-5).
    public static func walltimeNotice(command: String, max: TimeInterval) -> String {
        "compute gate: `\(shorten(command))` exceeded its declared max runtime "
            + "(\(DurationFormat.format(max))). Stop it now; it will be killed in "
            + "\(DurationFormat.format(Defaults.walltimeGrace))"
    }

    /// Soft stop by user (GATE-9).
    public static let softStopNotice =
        "compute gate: user needs the machine. Stop your running heavy jobs now, start no new ones; "
            + "continue without heavy runs or stop and report"

    /// Hard stop by user (GATE-10).
    public static let hardStopNotice =
        "compute gate: user hard-stopped heavy jobs; they are being killed. "
            + "Continue without heavy runs or stop and report"

    // MARK: Formatting helpers

    /// `HH:MM` in local time, or `?` when unknown.
    public static func clock(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func shorten(_ s: String, max: Int = 60) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }
}

/// Duration strings for `--max`: `90s`, `15m`, `1h`, `1h30m`, `2m30s`. A bare number means
/// minutes (`--max 20` = 20 min).
public enum DurationFormat {
    public static func parse(_ s: String) -> TimeInterval? {
        let s = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if let n = Double(s) { return n > 0 ? n * 60 : nil }
        var total: TimeInterval = 0
        var num = ""
        var sawUnit = false
        for ch in s {
            if ch.isNumber || ch == "." {
                num.append(ch)
            } else {
                guard let v = Double(num) else { return nil }
                switch ch {
                case "h": total += v * 3600
                case "m": total += v * 60
                case "s": total += v
                default: return nil
                }
                num = ""
                sawUnit = true
            }
        }
        guard num.isEmpty, sawUnit, total > 0 else { return nil }
        return total
    }

    /// Compact form: `45s`, `15m`, `1h`, `1h30m`, `2m30s`.
    public static func format(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var out = ""
        if h > 0 { out += "\(h)h" }
        if m > 0 { out += "\(m)m" }
        if s > 0 || out.isEmpty { out += "\(s)s" }
        return out
    }
}
