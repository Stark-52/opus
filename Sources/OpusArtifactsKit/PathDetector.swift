// PathDetector — pure token-scan for Cmd+click file[:line] detection (Lot 3,
// Task 5). Given a terminal line's text and a click column, finds the
// maximal run of "path-ish" characters around that column, parses an
// optional trailing `:line` or `:line:col` suffix (col discarded — the
// return type has nowhere to put it), and resolves the result against a
// working directory. `resolve` widens that to the rows around the click,
// for paths Claude Code wrapped or that hold spaces, and leaves the disk
// check to the `exists` closure it is given. No FileManager, no AppKit —
// existence-checking and opening are TerminalContainerView's job.

import Foundation

public enum PathDetector {
    /// Characters a path/file token can be made of. Deliberately narrow: no
    /// shell metacharacters, brackets, or quotes, so wrapping punctuation
    /// like the `(` `)` `,` in `(src/a.swift:3),` — and the `:` that
    /// introduces a line-number suffix — already falls outside a maximal
    /// run instead of needing to be trimmed off after the fact. The
    /// leading/trailing wrapper strip below is kept anyway as a defensive
    /// no-op against a future charset change, and because the brief calls
    /// for it explicitly.
    static func isTokenChar(_ c: Character) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "@", "~", ".", "/", "+", "%", "-":
            return true
        default:
            // Accented letters and non-Latin digits belong in a filename
            // just as much as ASCII ones do (French prose regularly names
            // a file "resume.pdf" with an accent on both e's).
            return !c.isASCII && (c.isLetter || c.isNumber)
        }
    }

    private static let leadingWrap: Set<Character> = ["(", "[", "{", "\"", "'"]
    private static let trailingWrap: Set<Character> = [",", ";", ":", ")", "]", "}", "\"", "'"]

    public static func extract(line: String, clickColumn: Int, cwd: String) -> (path: String, line: Int?)? {
        let chars = Array(line)
        guard !chars.isEmpty else { return nil }

        // Clamp the click column into bounds rather than failing on a
        // click past the end of a short line (trailing whitespace, a
        // narrower-than-expected row read, etc).
        let col = min(max(clickColumn, 0), chars.count - 1)
        guard isTokenChar(chars[col]) else { return nil }

        var start = col
        while start > 0, isTokenChar(chars[start - 1]) { start -= 1 }
        var end = col
        while end < chars.count - 1, isTokenChar(chars[end + 1]) { end += 1 }

        var token = String(chars[start...end])
        while let f = token.first, leadingWrap.contains(f) { token.removeFirst() }
        while let l = token.last, trailingWrap.contains(l) { token.removeLast() }
        guard !token.isEmpty, token.contains("/") || token.contains(".") else { return nil }

        let lineNumber = parseLineSuffix(chars, from: end + 1)

        return (resolvePath(token, cwd: cwd), lineNumber)
    }

    /// `chars[index]` is the character immediately after the token's end.
    /// Matches `:<digits>` (a further `:<digits>` column suffix, if present,
    /// is left unconsumed — its digits simply aren't part of this match, so
    /// it's implicitly discarded rather than folded into `lineNumber`).
    private static func parseLineSuffix(_ chars: [Character], from index: Int) -> Int? {
        guard index < chars.count, chars[index] == ":" else { return nil }
        var i = index + 1
        var digits = ""
        while i < chars.count, chars[i].isASCII, chars[i].isNumber {
            digits.append(chars[i])
            i += 1
        }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Expand `~`, then resolve against `cwd` when not already absolute.
    /// Plain string manipulation (append + standardize) — no disk access.
    static func resolvePath(_ token: String, cwd: String) -> String {
        let expanded = (token as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        let joined = (cwd as NSString).appendingPathComponent(expanded)
        return (joined as NSString).standardizingPath
    }

    /// How many words either side of the clicked one a name can take in.
    static let maxWordsAround = 6

    /// The file or folder a Cmd+click means, read from the rows around it
    /// (`rows[clickRow]` is the clicked one) and checked with `exists`.
    /// Claude Code wraps its own output, so a path can run onto the next row,
    /// broken at a space in a name ("Mes Images") or, when longer than a row,
    /// mid-word, and the break does not say which; a name can also hold
    /// spaces on one row. Every reading around the click is tried, longest
    /// first, so a folder cut short at the break never wins over the file it
    /// leads to; the clicked token alone, as `extract` reads it, comes last.
    /// A blank row ends the search, as it ends a paragraph.
    public static func resolve(rows: [String], clickRow: Int, clickColumn: Int, cwd: String,
                               exists: (String) -> Bool) -> (path: String, line: Int?)? {
        guard rows.indices.contains(clickRow) else { return nil }
        let clicked = Array(rows[clickRow])
        guard !clicked.isEmpty else { return nil }
        let col = min(max(clickColumn, 0), clicked.count - 1)
        guard isTokenChar(clicked[col]) else { return nil }

        let isBlank = { (row: String) in row.allSatisfy(\.isWhitespace) }
        var first = clickRow, last = clickRow
        while first > 0, !isBlank(rows[first - 1]) { first -= 1 }
        while last < rows.count - 1, !isBlank(rows[last + 1]) { last += 1 }

        // Each word with what separates it from the one before: the spaces
        // between them on a row, or nil for a row break.
        var words: [(text: String, gap: String?)] = []
        var clickedWord: Int?
        for row in first...last {
            let chars = Array(rows[row])
            var start = 0
            var previousEnd: Int?
            while start < chars.count {
                guard !chars[start].isWhitespace else { start += 1; continue }
                var end = start
                while end + 1 < chars.count, !chars[end + 1].isWhitespace { end += 1 }
                if row == clickRow, (start...end).contains(col) { clickedWord = words.count }
                words.append((String(chars[start...end]), previousEnd.map { String(chars[($0 + 1)..<start]) }))
                previousEnd = end
                start = end + 1
            }
        }
        guard let k = clickedWord else { return nil }

        var spans: [String] = []
        for i in max(0, k - maxWordsAround)...k {
            for j in k...min(words.count - 1, k + maxWordsAround) where j > i {
                let breaks = ((i + 1)...j).filter { words[$0].gap == nil }
                for spaced in 0..<(1 << breaks.count) {
                    var text = words[i].text
                    for m in (i + 1)...j {
                        if let gap = words[m].gap {
                            text += gap
                        } else if let bit = breaks.firstIndex(of: m), spaced & (1 << bit) != 0 {
                            text += " "
                        }
                        text += words[m].text
                    }
                    spans.append(text)
                }
            }
        }
        for span in spans.sorted(by: { $0.count > $1.count }) {
            for reading in readings(of: span, cwd: cwd) where exists(reading.path) {
                return reading
            }
        }

        guard let own = extract(line: rows[clickRow], clickColumn: col, cwd: cwd) else { return nil }
        if exists(own.path) { return own }
        if let stripped = trailingDotStripped(own.path), exists(stripped) { return (stripped, own.line) }
        return nil
    }

    /// What a stretch of text can name: without the punctuation wrapping it,
    /// then also without a sentence-ending dot, each with its `:line` (and
    /// `:col`) suffix split off.
    private static func readings(of span: String, cwd: String) -> [(path: String, line: Int?)] {
        var token = span
        while let f = token.first, leadingWrap.contains(f) { token.removeFirst() }
        while let l = token.last, trailingWrap.contains(l) { token.removeLast() }
        var withoutDot = token
        while let l = withoutDot.last, l == "." || trailingWrap.contains(l) { withoutDot.removeLast() }

        return (withoutDot == token ? [token] : [token, withoutDot]).compactMap { text in
            var name = text
            var line: Int?
            if let suffix = text.range(of: #":[0-9]+(:[0-9]+)?$"#, options: .regularExpression) {
                name = String(text[..<suffix.lowerBound])
                line = Int(text[suffix].dropFirst().prefix { $0 != ":" })
            }
            guard name.contains("/") || name.contains(".") else { return nil }
            return (resolvePath(name, cwd: cwd), line)
        }
    }

    /// A path candidate with sentence-ending dots removed, nil when unchanged.
    /// Trailing dots are part of the token charset (dotfiles, relative paths),
    /// so the caller retries with this variant when the primary path does not
    /// exist on disk.
    public static func trailingDotStripped(_ path: String) -> String? {
        var s = path
        while s.hasSuffix(".") { s.removeLast() }
        return s == path || s.isEmpty ? nil : s
    }
}
