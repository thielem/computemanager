import Foundation

// MARK: - cgate exit codes and user-facing messages
//
// Wire contract between cgate and its callers (docs/design.md §4 "cgate exit codes + output"); change both sides together.
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
    /// `run`: child could not be spawned (EX_SOFTWARE). Release reason `spawnFailed`.
    public static let spawnFailed: Int32 = 70
    /// `run`: cgate interrupted (SIGINT/SIGTERM forwarded to the child) = 128 + SIGINT.
    /// Release reason `interrupted`.
    public static let interrupted: Int32 = 130
    // `cgate run` otherwise exits with the child's exit code (128 + signal if signalled).

    /// Exit code for a hard stop directive.
    public static func forHardStop(_ reason: StopReason) -> Int32 {
        reason == .walltime ? walltimeKill : stoppedByUser
    }
}

public enum CgateMessage {
    /// Exit 76; also the `off` text in `acquire`; `cgate run` reports it.
    public static let gateOff = "Compute gate off — continue without heavy runs or stop and report"

    /// Exit 76 when the gate is on with 0 slots.
    public static let noSlots =
        "Compute gate: no slots configured — gate closed for new jobs. Continue without heavy runs or stop and report"

    /// Exit 75; also printed by `cgate run` when busy.
    public static func busy(_ t: TicketInfo) -> String {
        "compute busy: ticket \(t.id), position \(t.position), next slot \(latest(t.eta)), "
            + "then held for you \(human(t.holdSeconds ?? Defaults.ticketHold)). "
            + "Start `cgate wait --ticket \(t.id)` in the background now; you'll be notified when it "
            + "completes. Don't rely on any other message; do other work meanwhile"
    }

    /// `cgate run --wait` when busy: printed once, then it waits and runs by itself.
    public static func busyWaiting(_ t: TicketInfo) -> String {
        "compute busy: ticket \(t.id), position \(t.position), next slot \(latest(t.eta)); "
            + "waiting, the command starts by itself once the slot is free"
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

    /// `cgate wait` exit 0, and the "slot ready" notice text. `now` gives the time left to claim.
    public static func slotReady(ticket: String, heldUntil: Date, now: Date) -> String {
        "Slot ready for ticket \(ticket) — claim within \(human(heldUntil.timeIntervalSince(now))) with "
            + "`cgate run --ticket \(ticket) --max <est> -- '<cmd>'`, held until \(clock(heldUntil))."
    }

    // MARK: Stop notices (delivered once via the `"*"` hook, AGENT-5)

    /// Walltime reached (soft step of GATE-5).
    public static func walltimeNotice(command: String, max: TimeInterval, grace: TimeInterval) -> String {
        "compute gate: max runtime (\(DurationFormat.format(max))) of `\(shorten(command))` exceeded. "
            + "Stop it now — the process will be killed in \(human(grace))"
    }

    /// Soft stop of one job by user (per-job ✕, first press).
    public static func jobStopNotice(command: String) -> String {
        "compute gate: user asks you to stop your heavy job `\(shorten(command))` now; it will not be "
            + "killed automatically unless the user escalates. Continue without it or stop and report"
    }

    /// Soft stop by user (GATE-9).
    public static let softStopNotice =
        "compute gate: user needs the machine. Stop your running heavy jobs now and start no new ones; "
            + "they will not be killed automatically unless the user escalates. "
            + "Continue without heavy runs or stop and report"

    /// Hard stop by user (GATE-10).
    public static let hardStopNotice =
        "compute gate: user hard-stopped heavy jobs; they are being killed. "
            + "Continue without heavy runs or stop and report"

    // MARK: Formatting helpers

    /// ETAs are upper bounds (lease start + declared max runtime): `by ~10:53 (latest)`.
    public static func latest(_ date: Date?) -> String {
        date.map { "by ~\(clock($0)) (latest)" } ?? "time unknown"
    }

    /// `HH:MM` in local time, or `?` when unknown.
    public static func clock(_ date: Date?) -> String {
        guard let date else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Human duration: `2 min` for whole minutes ≥ 2, else `90 s`.
    public static func human(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return s >= 120 && s % 60 == 0 ? "\(s / 60) min" : "\(s) s"
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

/// Sender-side cap for command text sent over IPC (`AcquireRequest.command`).
public enum CommandText {
    public static let truncationMarker = "…[truncated]"

    /// `s` unchanged if ≤ `maxBytes` UTF-8 bytes; else its longest character-aligned prefix
    /// that fits together with `truncationMarker` (total ≤ `maxBytes`).
    public static func capped(_ s: String, maxBytes: Int = Defaults.maxCommandBytes) -> String {
        guard s.utf8.count > maxBytes else { return s }
        let budget = maxBytes - truncationMarker.utf8.count
        var used = 0
        var out = ""
        for ch in s {
            let n = String(ch).utf8.count
            guard used + n <= budget else { break }
            out.append(ch)
            used += n
        }
        return out + truncationMarker
    }
}
