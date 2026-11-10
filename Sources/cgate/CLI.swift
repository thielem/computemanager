import Foundation
import Shared

/// Parsed cgate invocation. Hand-rolled parser (no dependencies).
///
///   cgate run [--max <dur>] [--session <id>] [--ticket <id>] -- <cmd...>
///   cgate wait --ticket <id>
///   cgate hook            (reads Claude Code hook JSON on stdin)
///   cgate status
enum Command: Equatable {
    case run(RunOptions)
    case wait(ticket: String)
    case hook
    case status
    case help
}

struct RunOptions: Equatable {
    var maxRuntime: TimeInterval?
    var session: String?
    var ticket: String?
    var command: [String]
}

struct UsageError: Error, Equatable, CustomStringConvertible {
    var description: String
}

enum CLI {
    static let usage = """
        usage: cgate run [--max <dur>] [--session <id>] [--ticket <id>] -- <cmd...>
               cgate wait --ticket <id>
               cgate hook
               cgate status
        dur: 90s, 15m, 1h, 1h30m (bare number = minutes)
        """

    static func parse(_ args: [String]) throws -> Command {
        guard let sub = args.first else { throw UsageError(description: "missing subcommand") }
        let rest = Array(args.dropFirst())
        switch sub {
        case "run": return .run(try parseRun(rest))
        case "wait":
            let opts = try parseOptions(rest, allowed: ["--ticket"])
            guard opts.positional.isEmpty, let t = opts.values["--ticket"] else {
                throw UsageError(description: "wait requires --ticket <id>")
            }
            return .wait(ticket: t)
        case "hook", "status":
            guard rest.isEmpty else { throw UsageError(description: "\(sub) takes no arguments") }
            return sub == "hook" ? .hook : .status
        case "-h", "--help", "help": return .help
        default: throw UsageError(description: "unknown subcommand '\(sub)'")
        }
    }

    private static func parseRun(_ args: [String]) throws -> RunOptions {
        guard let dd = args.firstIndex(of: "--") else {
            throw UsageError(description: "run requires -- <cmd>")
        }
        let opts = try parseOptions(Array(args[..<dd]), allowed: ["--max", "--session", "--ticket"])
        guard opts.positional.isEmpty else {
            throw UsageError(description: "unexpected argument '\(opts.positional[0])'")
        }
        let cmd = Array(args[(dd + 1)...])
        guard !cmd.isEmpty else { throw UsageError(description: "empty command after --") }
        var max: TimeInterval?
        if let m = opts.values["--max"] {
            guard let d = DurationFormat.parse(m) else {
                throw UsageError(description: "invalid --max '\(m)'")
            }
            max = d
        }
        return RunOptions(maxRuntime: max, session: opts.values["--session"],
                          ticket: opts.values["--ticket"], command: cmd)
    }

    private static func parseOptions(_ args: [String], allowed: Set<String>) throws
        -> (values: [String: String], positional: [String])
    {
        var values: [String: String] = [:]
        var positional: [String] = []
        var i = 0
        while i < args.count {
            var a = args[i]
            var inline: String?
            if a.hasPrefix("--"), let eq = a.firstIndex(of: "=") {
                inline = String(a[a.index(after: eq)...])
                a = String(a[..<eq])
            }
            if a.hasPrefix("-") {
                guard allowed.contains(a) else { throw UsageError(description: "unknown option '\(a)'") }
                if let inline {
                    values[a] = inline
                } else {
                    guard i + 1 < args.count else { throw UsageError(description: "\(a) needs a value") }
                    values[a] = args[i + 1]
                    i += 1
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
        return (values, positional)
    }
}
