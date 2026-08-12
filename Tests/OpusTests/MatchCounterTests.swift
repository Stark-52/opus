import XCTest
@testable import Opus

final class MatchCounterTests: XCTestCase {
    func testEmptyTermReturnsZero() {
        XCTAssertEqual(MatchCounter.count(term: "", in: ["foo", "bar"]), 0)
    }

    func testNoMatchReturnsZero() {
        XCTAssertEqual(MatchCounter.count(term: "zzz", in: ["foo", "bar"]), 0)
    }

    func testSingleMatch() {
        XCTAssertEqual(MatchCounter.count(term: "foo", in: ["foo bar baz"]), 1)
    }

    func testMultipleMatchesAcrossLines() {
        XCTAssertEqual(MatchCounter.count(term: "error", in: ["error: one", "no match here", "error: two", "error again"]), 3)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(MatchCounter.count(term: "Error", in: ["error", "ERROR", "ErRoR"]), 3)
    }

    func testNonOverlappingOccurrences() {
        // "aaa" inside "aaaa": greedy left-to-right non-overlapping scan
        // finds exactly one match (chars 0-2), then has only "a" left
        // (chars 3) which is too short for a second "aaa".
        XCTAssertEqual(MatchCounter.count(term: "aaa", in: ["aaaa"]), 1)
    }

    func testTermLongerThanLineReturnsZero() {
        XCTAssertEqual(MatchCounter.count(term: "a very long search term", in: ["short"]), 0)
    }

    func testEmptyLinesArraySafe() {
        XCTAssertEqual(MatchCounter.count(term: "foo", in: []), 0)
    }
}
