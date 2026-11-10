import Foundation

/// Heavy-command matching for the hook (AGENT-3, AGENT-4).
///
/// Semantics:
/// - The command is split into segments at `&&`, `||`, `;`, `|`, `&`, newlines and `(`/`)`,
///   outside of quotes (`>&`, `<&`, `&>` are redirections, not separators). Quotes and
///   backslashes are honoured when splitting words. Heredoc bodies (`<<EOF`, `<<-EOF`,
///   `<<'EOF'`, `<<"EOF"`) are skipped; `<<<` here-strings are ordinary words.
/// - Harmless prefixes are stripped layer by layer and every layer is tried: `VAR=value`,
///   `time`/`env`/`nohup`/`exec`/`command` (+ their `-flags`), `timeout [-flags] N`,
///   `bash`/`sh`/`zsh [-flags]` (the script path is then matched; `-c '<line>'` is matched as a
///   command line), `uv run [--flags]`, `python[3] -m`, `npx [-flags]`, `pnpm exec`.
/// - A pattern (`"swift test"`) matches a segment whose first words equal the pattern's words.
///   The first word also matches by basename when the pattern word has no `/`
///   (`check.sh` matches `./scripts/check.sh`, `make` matches `/usr/bin/make`, not `cmake`).
/// - A command matches when any segment (any layer) matches any pattern.
/// - Already gated: the line is exactly one `cgate` invocation (any path, after prefixes).
///   Mixed lines (`cgate status; swift test`) are treated like any other.
enum CommandMatcher {
    private static let prefixWords: Set<String> = ["time", "env", "nohup", "exec", "command"]
    private static let shells: Set<String> = ["bash", "sh", "zsh"]
    private static let uvValueFlags: Set<String> = [
        "--with", "--with-requirements", "--python", "-p", "--project", "--directory", "--package",
        "--extra", "--group", "--env-file", "--index", "--from",
    ]

    static func matches(_ command: String, patterns: [String]) -> Bool {
        let pats = patterns.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { !$0.isEmpty }
        return matches(command, pats, depth: 0)
    }

    private static func matches(_ command: String, _ pats: [[String]], depth: Int) -> Bool {
        segments(command).contains { seg in
            layers(seg).contains { layer in
                if depth < 3, let line = shellDashC(layer), matches(line, pats, depth: depth + 1) { return true }
                return pats.contains { matches(layer, $0) }
            }
        }
    }

    static func isWrapped(_ command: String) -> Bool {
        let segs = segments(command)
        guard segs.count == 1 else { return false }
        return layers(segs[0]).contains { basename($0[0]) == "cgate" }
    }

    /// True if `ticket` appears as a whole word (or `--ticket=<id>`) in a cgate segment.
    static func mentionsTicket(_ command: String, _ ticket: String) -> Bool {
        segments(command).contains { seg in
            layers(seg).contains { basename($0[0]) == "cgate" }
                && seg.contains { $0 == ticket || $0 == "--ticket=\(ticket)" }
        }
    }

    /// Hook deny reason for a heavy command not run via cgate (K1: the hook never rewrites).
    static func redirect(_ command: String) -> String {
        "Compute gate: heavy command. Re-run as: cgate run --max <estimate> -- "
            + singleQuote(command) + " with run_in_background: true"
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./:=@%+,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return singleQuote(s)
    }

    static func singleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
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

    /// The segment and every non-empty result of stripping prefixes one layer at a time.
    static func layers(_ seg: [String]) -> [[String]] {
        var out: [[String]] = []
        var cur: ArraySlice<String>? = seg[...]
        while let c = cur, !c.isEmpty, out.count < 16 {
            out.append(Array(c))
            cur = stripOnce(c)
        }
        return out
    }

    /// `bash -c '<line>'` (also `-lc`, `-ec`, …) → `<line>`.
    private static func shellDashC(_ w: [String]) -> String? {
        guard shells.contains(basename(w[0])) else { return nil }
        var i = 1
        while i < w.count, w[i].hasPrefix("-") {
            if !w[i].hasPrefix("--"), w[i].hasSuffix("c") { return i + 1 < w.count ? w[i + 1] : nil }
            i += 1
        }
        return nil
    }

    private static func dropFlags(_ w: ArraySlice<String>) -> ArraySlice<String> {
        var w = w
        while let f = w.first, f.hasPrefix("-") { w = w.dropFirst() }
        return w
    }

    /// One prefix layer removed, or nil if the segment starts with no known prefix.
    private static func stripOnce(_ w: ArraySlice<String>) -> ArraySlice<String>? {
        guard let f = w.first else { return nil }
        let rest = w.dropFirst()
        let b = basename(f)
        if isAssignment(f) { return rest }
        if prefixWords.contains(f) { return dropFlags(rest) }
        if f == "timeout" {
            var r = rest
            while let x = r.first, x.hasPrefix("-") {
                r = r.dropFirst(["-s", "-k", "--signal", "--kill-after"].contains(x) ? 2 : 1)
            }
            if let d = r.first, d.first?.isNumber == true { r = r.dropFirst() }
            return r
        }
        if shells.contains(b) {
            return shellDashC(Array(w)) == nil ? dropFlags(rest) : nil  // -c: matched as a line
        }
        if f == "uv", rest.first == "run" {
            var r = rest.dropFirst()
            while let x = r.first, x.hasPrefix("-") { r = r.dropFirst(uvValueFlags.contains(x) ? 2 : 1) }
            return r
        }
        if b == "python" || b == "python3", rest.first == "-m" { return rest.dropFirst() }
        if f == "npx" { return dropFlags(rest) }
        if f == "pnpm", rest.first == "exec" { return dropFlags(rest.dropFirst()) }
        return nil
    }

    /// Non-empty word lists per segment (prefixes not stripped), heredoc bodies skipped.
    static func segments(_ command: String) -> [[String]] {
        let cs = Array(command)
        var segs: [[String]] = []
        var words: [String] = []
        var word = ""
        var inWord = false
        var quote: Character?
        var escape = false
        var heredocs: [(delim: String, dash: Bool)] = []

        func endWord() {
            if inWord { words.append(word) }
            word = ""
            inWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segs.append(words) }
            words = []
        }

        var i = 0
        while i < cs.count {
            let ch = cs[i]
            i += 1
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
            case "<" where i < cs.count && cs[i] == "<":
                if i + 1 < cs.count && cs[i + 1] == "<" {  // here-string
                    word += "<<<"; inWord = true; i += 2
                    continue
                }
                endWord()
                i += 1
                let dash = i < cs.count && cs[i] == "-"
                if dash { i += 1 }
                while i < cs.count, cs[i] == " " || cs[i] == "\t" { i += 1 }
                var delim = ""
                var q: Character?
                while i < cs.count {
                    let c = cs[i]
                    if let qq = q {
                        if c == qq { q = nil } else { delim.append(c) }
                    } else if c == "'" || c == "\"" {
                        q = c
                    } else if " \t\n;&|<>()".contains(c) {
                        break
                    } else if c != "\\" {  // `<<\EOF` quotes the delimiter
                        delim.append(c)
                    }
                    i += 1
                }
                if !delim.isEmpty { heredocs.append((delim, dash)) }
            case "&" where (i >= 2 && (cs[i - 2] == ">" || cs[i - 2] == "<")) || (i < cs.count && cs[i] == ">"):
                word.append(ch); inWord = true
            case "\n":
                endSegment()
                // Skip pending heredoc bodies, line by line, through each delimiter line.
                for h in heredocs {
                    while i < cs.count {
                        var end = i
                        while end < cs.count, cs[end] != "\n" { end += 1 }
                        var line = cs[i..<end]
                        if h.dash { while line.first == "\t" { line = line.dropFirst() } }
                        i = min(end + 1, cs.count)
                        if String(line) == h.delim { break }
                    }
                }
                heredocs = []
            case ";", "&", "|", "(", ")": endSegment()
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
