// TextArtifactScanner — whole-line scanning for the artifacts drawer.
//
// PathDetector answers "what path is under this click column". The drawer
// has no click, so it needs "every path-ish token on this line" instead.
// The charset is deliberately shared with PathDetector rather than
// restated: two definitions of "what a path looks like" would drift, and
// the Cmd+click behaviour and the drawer's contents would stop agreeing.
//
// URLs get their own scanner because PathDetector structurally cannot see
// them: `:` is excluded from its charset, so `http` always splits before
// `://`. Worse, a token starting at `//example.com` resolves as an
// absolute path. This scanner runs FIRST and its matches are masked out of
// the text before the path scan, so a URL never also appears as a path.

import Foundation

public enum TextArtifactScanner {

    // MARK: - URLs

    private static let schemes = ["https://", "http://"]

    /// Characters legal inside a URL once the scheme is past. Space, quotes
    /// and angle brackets end it; everything else is kept and trimmed
    /// afterwards, because a `.` or `)` can be either part of the URL or
    /// the sentence around it and only position tells them apart.
    private static func isURLChar(_ c: Character) -> Bool {
        !c.isWhitespace && c != "\"" && c != "'" && c != "<" && c != ">" && c != "`"
    }

    /// Punctuation that ends a sentence rather than a URL.
    private static let urlTrailingTrim: Set<Character> = [".", ",", ";", ":", "!", "?"]

    public static func urls(in text: String) -> [String] {
        rawURLRanges(in: text).compactMap { range in
            let candidate = String(text[range])
            guard URL(string: candidate) != nil else { return nil }
            return candidate
        }
    }

    /// Ranges of the trimmed URL matches, in reading order. Shared with
    /// `paths` so the path scan can skip them.
    private static func rawURLRanges(in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let start = schemes
                .compactMap({ text.range(of: $0, range: cursor..<text.endIndex)?.lowerBound })
                .min()
            else { break }

            var end = start
            while end < text.endIndex, isURLChar(text[end]) { end = text.index(after: end) }

            // Trim sentence punctuation, and unbalanced closing parens or
            // brackets. `.../A_(b)` keeps its paren because the URL opened
            // one; `(see .../docs)` loses it because it did not.
            while end > start {
                let last = text[text.index(before: end)]
                if urlTrailingTrim.contains(last) {
                    end = text.index(before: end)
                } else if last == ")" || last == "]" {
                    let open: Character = last == ")" ? "(" : "["
                    let body = text[start..<end]
                    if body.filter({ $0 == open }).count < body.filter({ $0 == last }).count {
                        end = text.index(before: end)
                    } else { break }
                } else { break }
            }

            if end > start, text.distance(from: start, to: end) > 8 {
                result.append(start..<end)
            }
            cursor = end > start ? end : text.index(after: start)
        }
        return result
    }

    // MARK: - Paths

    /// Every maximal run of path characters that could name a file, in
    /// reading order, unresolved and unexpanded. A candidate must be at
    /// least 3 characters and contain a `/` or a `.`; everything past that
    /// is the disk's job, not this scanner's. Accepting `v1.2.3` here and
    /// letting ArtifactClassifier drop it is deliberate: no rule of form
    /// separates a version number from a filename, only existence does.
    public static func paths(in text: String) -> [String] {
        let masked = maskingURLs(in: text)
        var result: [String] = []
        var token = ""
        func flush() {
            defer { token = "" }
            guard token.count >= 3 else { return }
            guard token.contains("/") || token.contains(".") else { return }
            result.append(token)
        }
        for c in masked {
            if PathDetector.isTokenChar(c) { token.append(c) } else { flush() }
        }
        flush()
        return result
    }

    /// Replace every URL match with spaces of the same length, so index
    /// arithmetic elsewhere is unaffected and the path scanner simply sees
    /// whitespace where a URL was.
    private static func maskingURLs(in text: String) -> String {
        let ranges = rawURLRanges(in: text)
        guard !ranges.isEmpty else { return text }
        var out = text
        for range in ranges.reversed() {
            let width = text.distance(from: range.lowerBound, to: range.upperBound)
            out.replaceSubrange(range, with: String(repeating: " ", count: width))
        }
        return out
    }
}
