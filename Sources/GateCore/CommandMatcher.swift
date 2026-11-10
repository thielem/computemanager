import Foundation

/// Auto-wrap pattern matching (AGENT-3, AGENT-4).
///
/// Semantics:
/// - The command is split into segments at `&&`, `||`, `;`, `|`, `&`, newlines and `(`/`)`,
///   outside of quotes. Quotes and backslashes are honoured when splitting words.
/// - In each segment, leading `VAR=value` assignments and the prefixes `time`, `env`, `nohup`,
///   `exec`, `command` are skipped.
/// - A pattern (`"swift test"`) matches a segment whose first words equal the pattern's words.
///   The first word also matches by basename when the pattern word has no `/`
///   (`check.sh` matches `./scripts/check.sh`, `make` matches `/usr/bin/make`, not `cmake`).
/// - A command matches when any segment matches any pattern.
/// - Already wrapped: any segment that starts with `cgate` (any path) → never wrapped again.
enum CommandMatcher {
    private static let prefixWords: Set<String> = ["time", "env", "nohup", "exec", "command"]

    static func matches(_ command: String, patterns: [String]) -> Bool {
        let pats = patterns.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
        return segments(command).contains { seg in pats.contains { matches(seg, $0) } }
    }

    static func isWrapped(_ command: String) -> Bool {
        segments(command).contains { basename($0[0]) == "cgate" }
    }

    /// True if `ticket` appears as a whole word (or `--ticket=<id>`) in a cgate command.
    static func mentionsTicket(_ command: String, _ ticket: String) -> Bool {
        guard isWrapped(command) else { return false }
        return segments(command).joined().contains { $0 == ticket || $0 == "--ticket=\(ticket)" }
    }

    /// `cgate run --session <sid> [--ticket <t>] -- '<cmd>'` (cgate runs a single argument
    /// through the shell).
    static func wrap(_ command: String, sessionId: String, ticket: String?) -> String {
        var s = "cgate run --session \(shellQuote(sessionId))"
        if let ticket { s += " --ticket \(shellQuote(ticket))" }
        return s + " -- " + shellQuote(command)
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Internals

    private static func matches(_ seg: [String], _ pat: [String]) -> Bool {
        guard seg.count >= pat.count else { return false }
        let first = pat[0].contains("/") ? seg[0] == pat[0] : basename(seg[0]) == pat[0]
        return first && zip(seg.dropFirst(), pat.dropFirst()).allSatisfy(==)
    }

    private static func basename(_ w: String) -> String {
        w.split(separator: "/").last.map(String.init) ?? w
    }

    /// Non-empty word lists per segment, with assignments / prefix words stripped.
    static func segments(_ command: String) -> [[String]] {
        var segs: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escape = false

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            var w = words[...]
            while let f = w.first, isAssignment(f) || prefixWords.contains(f) || (f.hasPrefix("-") && w.startIndex > words.startIndex) {
                w = w.dropFirst()
            }
            if !w.isEmpty { segs.append(Array(w)) }
            words = []
        }

        for ch in command {
            if escape {
                word.append(ch); inWord = true; escape = false
                continue
            }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\" && q == "\"" { escape = true } else { word.append(ch) }
                continue
            }
            switch ch {
            case "\\": escape = true; inWord = true
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t": endWord()
            case "\n", ";", "&", "|", "(", ")": endSegment()
            default: word.append(ch); inWord = true
            }
        }
        endSegment()
        return segs
    }

    private static func isAssignment(_ w: String) -> Bool {
        guard let eq = w.firstIndex(of: "="), eq != w.startIndex else { return false }
        let name = w[..<eq]
        return name.first.map { $0 == "_" || $0.isLetter } == true
            && name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
