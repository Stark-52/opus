// WebAddress — a web address written without its scheme
// ("demo.example.pro/essai"), the way Claude Code often prints one. On disk
// it names nothing, so PathDetector cannot open it, and SwiftTerm's own link
// detection takes it for a relative path and blocks it. A link with its
// scheme is SwiftTerm's to open and is left alone here.

import Foundation

public enum WebAddress {
    /// Endings a domain written alone can have. A bare `name.ext` is far more
    /// often a file Claude mentioned (`notes.txt`, `main.py`, `Opus.app`), so
    /// only endings that are not common file extensions count; with a path
    /// after it, or `www.` before it, any alphabetic ending does.
    static let bareDomainEndings: Set<String> = [
        "com", "org", "net", "io", "dev", "pro", "xyz", "ai", "co", "me", "fr", "eu", "be",
        "ch", "de", "es", "it", "uk", "ca", "us", "gg", "tv", "info", "biz", "tech", "site",
        "online", "store", "cloud", "studio", "page", "blog", "news",
    ]

    private static let leadingWrap: Set<Character> = ["(", "[", "{", "\"", "'", "«", "“", "‘", "<"]
    private static let trailingWrap: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}",
                                                       "\"", "'", "»", "”", "’", ">"]

    /// The https URL for the scheme-less web address under the click, or nil.
    /// The host must be lowercase, which already sets apart most file names.
    public static func at(line: String, clickColumn: Int) -> URL? {
        let chars = Array(line)
        guard !chars.isEmpty else { return nil }
        let col = min(max(clickColumn, 0), chars.count - 1)
        guard !chars[col].isWhitespace else { return nil }
        var start = col
        while start > 0, !chars[start - 1].isWhitespace { start -= 1 }
        var end = col
        while end < chars.count - 1, !chars[end + 1].isWhitespace { end += 1 }

        var word = String(chars[start...end])
        while let f = word.first, leadingWrap.contains(f) { word.removeFirst() }
        while let l = word.last, trailingWrap.contains(l) { word.removeLast() }
        guard !word.contains("://"), !word.contains("@") else { return nil }

        let host = word.prefix { $0 != "/" }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
              }),
              let ending = labels.last, ending.count >= 2, ending.allSatisfy(\.isLetter)
        else { return nil }
        let hasPath = host.count < word.count
        guard hasPath || labels.first == "www" || bareDomainEndings.contains(String(ending)) else { return nil }
        return URL(string: "https://" + word)
    }
}
