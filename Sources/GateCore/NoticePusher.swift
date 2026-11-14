import Darwin
import Foundation
import Shared

/// Secondary notice channel (AGENT-10): one user message into a Claude Code session via its
/// messaging socket (`/tmp/cc-socks/<claude-pid>.sock`, see `ClaudeMessaging`).
/// The server never has the session token; testing showed auth is optional on macOS, so only the
/// `user` line is sent (an `auth` line is sent first when a token is given).
struct NoticePusher: Sendable {
    /// Deliver `text` to the session socket. Best effort; errors are swallowed by the caller.
    var push: @Sendable (_ socket: String, _ text: String) -> Void
    /// Messaging socket of a session the gate has no socket for (e.g. ticket from the hook).
    var resolveSocket: @Sendable (_ sessionId: String) -> String?

    /// Real delivery, restricted to Claude Code's socket directory.
    static let live = NoticePusher(
        push: { socket, text in
            guard MessagingSocket.isClaudeSocket(socket) else { return }
            try? MessagingSocket.send(path: socket, token: nil, text: text)
        },
        resolveSocket: { ClaudeSessions.messagingSocket(for: $0) })

    static let none = NoticePusher(push: { _, _ in }, resolveSocket: { _ in nil })
}

enum MessagingSocket {
    static func isClaudeSocket(_ path: String) -> Bool {
        (path.hasPrefix("/tmp/cc-socks/") || path.hasPrefix("/private/tmp/cc-socks/"))
            && path.hasSuffix(".sock") && !path.contains("..")
    }

    /// NDJSON: optional `{"type":"auth","token":…}`, then `{"type":"user","message":{…}}`.
    static func lines(token: String?, text: String) throws -> Data {
        var out = Data()
        if let token {
            out += try JSONSerialization.data(withJSONObject: ["type": "auth", "token": token])
            out += Data("\n".utf8)
        }
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        out += try JSONSerialization.data(withJSONObject: msg)
        out += Data("\n".utf8)
        return out
    }

    static func send(path: String, token: String?, text: String, timeout: TimeInterval = 1) throws {
        let payload = try lines(token: token, text: text)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes + [0]) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw SocketError.syscall("connect", errno) }
        try payload.withUnsafeBytes { buf in
            var off = 0
            while off < buf.count {
                let n = write(fd, buf.baseAddress! + off, buf.count - off)
                guard n > 0 else { throw SocketError.syscall("write", errno) }
                off += n
            }
        }
    }
}

/// Read-only lookup in Claude Code's `~/.claude/sessions/<pid>.json` registry
/// (`sessionId`, `messagingSocketPath`).
enum ClaudeSessions {
    static func messagingSocket(for sessionId: String,
                                directory: String = NSHomeDirectory() + "/.claude/sessions") -> String? {
        guard sessionId != GateMachine.unknownSession,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        for name in names where name.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: directory + "/" + name),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["sessionId"] as? String == sessionId else { continue }
            return obj["messagingSocketPath"] as? String
        }
        return nil
    }
}
