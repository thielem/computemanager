import Foundation
import Shared

/// `cgate wait --ticket <id>` (AGENT-1a): long-poll until the ticket's slot is held (exit 0)
/// or the ticket expired (exit 79). App unreachable → exit 0 (fail open: run ungated).
enum Waiter {
    static func run(ticket: String, link: GateLink, stderr: (String) -> Void,
                    pollTimeout: TimeInterval = Defaults.waitTicketPollWindow + 5) -> Int32 {
        while true {
            switch try? link.call(.waitTicket(WaitTicketRequest(ticket: ticket)), timeout: pollTimeout) {
            case .waitTicket(.ready(let t, let until))?:
                stderr(CgateMessage.slotReady(ticket: t, heldUntil: until, now: Date()))
                return CgateExit.ok
            case .waitTicket(.expired(let t))?:
                stderr(CgateMessage.ticketExpired(t))
                return CgateExit.ticketExpired
            case .waitTicket(.pending)?:
                continue
            default:
                stderr("compute gate not running: run your command directly (cgate run works ungated)")
                return CgateExit.ok
            }
        }
    }
}

/// `cgate status` (AGENT-9).
enum StatusCommand {
    static func render(_ s: GateStatus, now: Date = Date()) -> String {
        var out = ["gate \(s.level.rawValue), slots \(s.leases.count)/\(s.effectiveSlots)"
            + (s.nextSlotETA.map { ", next slot \(CgateMessage.latest($0))" } ?? "")]
        for l in s.leases {
            let elapsed = DurationFormat.format(max(0, now.timeIntervalSince(l.startedAt)))
            let cmd = l.command.count <= 60 ? l.command : String(l.command.prefix(59)) + "…"
            out.append("  \(l.displayName) [\(l.sessionId.prefix(8))] \(elapsed)/\(DurationFormat.format(l.maxRuntimeSeconds)) "
                + "\(l.state.rawValue)  \(cmd)")
        }
        for t in s.tickets {
            let held = s.heldSlot?.ticketId == t.id ? " held until \(CgateMessage.clock(s.heldSlot?.until))" : ""
            out.append("  ticket \(t.id) #\(t.position) slot \(CgateMessage.latest(t.eta))\(held)")
        }
        return out.joined(separator: "\n")
    }
}
