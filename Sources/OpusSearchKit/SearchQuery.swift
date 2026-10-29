// SearchQuery — how every Opus search box matches what is typed.
//
// The query is cut into words on spaces, dashes, underscores, dots and
// slashes; every word must appear somewhere in the fields searched, in any
// order, case and accents aside. A word may also run over a separator the
// person left out, so "mongodburi" finds "mongodb-uri".

import Foundation

public struct SearchQuery {
    private let words: [String]

    public init(_ text: String) {
        words = Self.fold(text)
            .split(whereSeparator: Self.isSeparator)
            .map(String.init)
    }

    /// A query with no word in it filters nothing.
    public var isEmpty: Bool { words.isEmpty }

    public func matches(_ fields: String...) -> Bool {
        matches(fields)
    }

    public func matches(_ fields: [String]) -> Bool {
        guard !words.isEmpty else { return true }

        let folded = Self.fold(fields.joined(separator: " "))
        let spaced = String(folded.map { Self.isSeparator($0) ? " " : $0 })
        let joined = String(folded.filter { !Self.isSeparator($0) })

        return words.allSatisfy { spaced.contains($0) || joined.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || "-_./".contains(character)
    }
}
