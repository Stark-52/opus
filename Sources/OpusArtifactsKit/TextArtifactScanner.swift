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
//
// Fix round 1 (Task 2 review): scheme detection used to repeat a
// range(of:) search for both "https://" and "http://" on every outer-loop
// iteration, each one scanning to the end of the remaining text whenever
// the other scheme did not occur again, which is quadratic on a line with
// many URL-shaped substrings. It also only recognised those two literal
// schemes, so "ftp://" and "file://" were not masked and leaked their
// //host/path half into paths(in:) results. Both are fixed by a single
// linear scan for the generic "://" separator, reading the scheme word
// backwards from it: any scheme is now masked out of the path scan, and
// urls(in:) filters that same scan down to http/https before returning.

import Foundation

public enum TextArtifactScanner {

    // MARK: - URLs

    /// Characters legal inside a URL once the scheme is past. Space,
    /// straight quotes, angle brackets, and backtick end it; so do the
    /// curly quotes and guillemets that French prose (and other
    /// languages) wraps a URL in, since none of those are legal in a URL
    /// and Foundation's `URL(string:)` does not reject them, it silently
    /// punycodes them into the host. Everything else is kept and trimmed
    /// afterwards, because a `.` or `)` can be either part of the URL or
    /// the sentence around it and only position tells them apart.
    private static let excludedURLChars: Set<Character> = [
        "\"", "'", "<", ">", "`",
        "\u{00AB}", "\u{00BB}", // « »
        "\u{2018}", "\u{2019}", // ‘ ’
        "\u{201C}", "\u{201D}", // “ ”
        "\u{2039}", "\u{203A}"  // ‹ ›
    ]

    private static func isURLChar(_ c: Character) -> Bool {
        !c.isWhitespace && !excludedURLChars.contains(c)
    }

    /// Punctuation that ends a sentence rather than a URL.
    private static let urlTrailingTrim: Set<Character> = [".", ",", ";", ":", "!", "?"]

    /// ASCII letters and digits, the characters a URL scheme name is made
    /// of (RFC 3986 also allows "+", "-", "." inside a scheme, but no
    /// artifact this app cares about needs those, and admitting them risks
    /// swallowing an unrelated word that happens to sit before a stray
    /// "://").
    private static func isSchemeChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    private struct SchemeMatch {
        let range: Range<String.Index>
        let scheme: String
    }

    public static func urls(in text: String) -> [String] {
        schemeMatches(in: text).compactMap { match in
            guard match.scheme == "http" || match.scheme == "https" else { return nil }
            let candidate = String(text[match.range])
            guard URL(string: candidate) != nil else { return nil }
            return candidate
        }
    }

    /// A single linear pass for the "://" separator, in reading order.
    /// Any scheme word is captured here, not only http/https, so
    /// `maskingURLs` can blank out every link-shaped span before the path
    /// scan runs; `urls(in:)` is the one that narrows this down to the
    /// schemes this app treats as artifacts. Searching for one fixed
    /// separator instead of two whole scheme strings means each search
    /// only has to cover the gap to the next occurrence rather than
    /// rescanning to the end of the text when the other scheme does not
    /// occur again, which is what made the old two-scheme version
    /// quadratic on lines dense with URL-shaped substrings.
    private static func schemeMatches(in text: String) -> [SchemeMatch] {
        var result: [SchemeMatch] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let sep = text.range(of: "://", range: searchStart..<text.endIndex) {
            var schemeStart = sep.lowerBound
            while schemeStart > text.startIndex, isSchemeChar(text[text.index(before: schemeStart)]) {
                schemeStart = text.index(before: schemeStart)
            }
            guard schemeStart < sep.lowerBound else {
                // No scheme word directly before "://" (e.g. a bare "://").
                searchStart = sep.upperBound
                continue
            }
            let scheme = String(text[schemeStart..<sep.lowerBound])

            var end = sep.upperBound
            while end < text.endIndex, isURLChar(text[end]) { end = text.index(after: end) }

            // Trim sentence punctuation, and unbalanced closing parens or
            // brackets. `.../A_(b)` keeps its paren because the URL opened
            // one; `(see .../docs)` loses it because it did not.
            while end > schemeStart {
                let last = text[text.index(before: end)]
                if urlTrailingTrim.contains(last) {
                    end = text.index(before: end)
                } else if last == ")" || last == "]" {
                    let open: Character = last == ")" ? "(" : "["
                    let body = text[schemeStart..<end]
                    if body.filter({ $0 == open }).count < body.filter({ $0 == last }).count {
                        end = text.index(before: end)
                    } else { break }
                } else { break }
            }

            if end > schemeStart, text.distance(from: schemeStart, to: end) > 8 {
                result.append(SchemeMatch(range: schemeStart..<end, scheme: scheme))
                searchStart = end
            } else {
                searchStart = sep.upperBound
            }
        }
        return result
    }

    // MARK: - Paths

    /// Every maximal run of path characters that could name a file, in
    /// reading order, unresolved and unexpanded. A candidate must be at
    /// least 3 characters, contain a `/` or a `.`, and contain at least one
    /// letter or digit; everything past that is the disk's job, not this
    /// scanner's. Accepting `v1.2.3` here and letting ArtifactClassifier
    /// drop it is deliberate: no rule of form separates a version number
    /// from a filename, only existence does.
    ///
    /// The letter-or-digit rule is the one exception, added by the final
    /// whole-branch review after running this over the owner's real
    /// transcripts. Punctuation-only tokens name nothing, but they are not
    /// harmless: `///` (74 occurrences in one session, from Swift doc
    /// comment markers in assistant prose) is 3 characters and contains a
    /// `/`, so it passed, resolved to `/`, and `/` exists — which means the
    /// existence filter the whole text-scanning design leans on could not
    /// cull it, and last-mention-wins ordering kept re-bumping the root to
    /// the top of the drawer. `//.` and `...` are the same shape.
    public static func paths(in text: String) -> [String] {
        let masked = maskingURLs(in: text)
        var result: [String] = []
        var token = ""
        func flush() {
            defer { token = "" }
            guard token.count >= 3 else { return }
            guard token.contains("/") || token.contains(".") else { return }
            guard token.contains(where: { $0.isLetter || $0.isNumber }) else { return }
            result.append(token)
        }
        for c in masked {
            if PathDetector.isTokenChar(c) { token.append(c) } else { flush() }
        }
        flush()
        return result
    }

    /// Replace every scheme match (any scheme, not only http/https) with
    /// spaces of the same length, so index arithmetic elsewhere is
    /// unaffected and the path scanner simply sees whitespace where a URL
    /// was.
    private static func maskingURLs(in text: String) -> String {
        let ranges = schemeMatches(in: text).map { $0.range }
        guard !ranges.isEmpty else { return text }
        var out = text
        for range in ranges.reversed() {
            let width = text.distance(from: range.lowerBound, to: range.upperBound)
            out.replaceSubrange(range, with: String(repeating: " ", count: width))
        }
        return out
    }
}
