// MatchCounter — pure, testable match counting for the Cmd+F "n / total"
// readout (Fix 2, v1.4.2).
//
// SwiftTerm's own match-counting engine (SearchService.findAll) is
// `internal`, not `public` — not usable from Opus. This is our own,
// independent scan over lines harvested from the terminal's PUBLIC buffer
// API (see TerminalContainerView.harvestBufferLines), so it necessarily
// counts using its own definition of a "match" — case-insensitive,
// non-overlapping substring occurrences — which is not guaranteed to be
// pixel-identical to SwiftTerm's internal search cursor in every edge case
// (see the drift note on TerminalContainerView.matchIndex).

import Foundation

enum MatchCounter {
    /// Case-insensitive occurrence count of `term` across `lines`, counting
    /// NON-OVERLAPPING occurrences within each line (e.g. "aaa" inside
    /// "aaaa" counts once, not twice). Empty term → 0.
    static func count(term: String, in lines: [String]) -> Int {
        guard !term.isEmpty else { return 0 }
        return lines.reduce(0) { $0 + occurrences(of: term, in: $1) }
    }

    /// Non-overlapping, case-insensitive occurrence count of `term` within
    /// a single line: each match's `upperBound` becomes the start of the
    /// next search, so a found match can never be re-matched by a
    /// subsequent overlapping search.
    private static func occurrences(of term: String, in line: String) -> Int {
        var count = 0
        var searchRange = line.startIndex..<line.endIndex
        while let range = line.range(of: term, options: .caseInsensitive, range: searchRange) {
            count += 1
            searchRange = range.upperBound..<line.endIndex
        }
        return count
    }
}
