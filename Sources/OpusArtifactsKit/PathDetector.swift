// PathDetector — pure token-scan for Cmd+click file[:line] detection (Lot 3,
// Task 5). Given a terminal line's text and a click column, finds the
// maximal run of "path-ish" characters around that column, parses an
// optional trailing `:line` or `:line:col` suffix (col discarded — the
// return type has nowhere to put it), and resolves the result against a
// working directory. No FileManager, no AppKit — existence-checking and
// opening are TerminalContainerView's job, not this one's.

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
            return false
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
