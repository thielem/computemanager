import Darwin
import Foundation
import Shared

/// One request/response to the gate app, on a fresh connection. Retries once (after ~100 ms)
/// on `.closed` (e.g. connection cap hit). Any thrown error = app unreachable / unusable →
/// callers fail open.
struct GateLink: Sendable {
    var path: String

    func call(_ req: GateRequest, timeout: TimeInterval = Defaults.clientTimeout) throws -> GateReply {
        let deadline = Date().addingTimeInterval(timeout)
        do {
            return try once(req, timeout: timeout)
        } catch SocketError.closed {
            usleep(100_000)
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { throw SocketError.timeout }
            return try once(req, timeout: left)
        }
    }

    private func once(_ req: GateRequest, timeout: TimeInterval) throws -> GateReply {
        let c = try GateClient(path: path, timeout: timeout)
        defer { c.close() }
        return try c.call(req)
    }
}

/// Claude Code session id for explicit runs (AGENT-6): `CLAUDE_CODE_SESSION_ID`, else
/// `~/.claude/sessions/<pid>.json` of `CLAUDE_PID` or an ancestor process, else `unknown`.
enum SessionLookup {
    static func resolve(env: [String: String],
                        sessionsDir: String = NSHomeDirectory() + "/.claude/sessions") -> String {
        if let s = env["CLAUDE_CODE_SESSION_ID"], !s.isEmpty { return s }
        var pids: [Int32] = []
        if let p = env["CLAUDE_PID"].flatMap(Int32.init) { pids.append(p) }
        var p = getppid()
        for _ in 0..<5 where p > 1 {
            pids.append(p)
            p = parentPid(of: p)
        }
        for pid in pids {
            guard let data = FileManager.default.contents(atPath: "\(sessionsDir)/\(pid).json"),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String else { continue }
            return sid
        }
        return "unknown"
    }

    static func parentPid(of pid: Int32) -> Int32 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }
}

/// Single-quote for POSIX shells (used to display argv-form commands).
func shellQuote(_ s: String) -> String {
    let safe = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
    if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
}
