// StatusRailTests — pure formatting coverage for StatusRailView.readoutText.
// The view itself (rail fill, activity dot, label color escalation) is
// AppKit drawing with no independently-testable branches beyond this
// formatter, so this is the full red/green loop for Task 2 — see
// task-2-brief.md.

import XCTest
@testable import Opus

final class StatusRailTests: XCTestCase {
    func testReadoutFormatsPercentAndTokens() {
        XCTAssertEqual(StatusRailView.readoutText(tokens: 353_112, limit: 1_000_000), "35% · 353k")
        XCTAssertEqual(StatusRailView.readoutText(tokens: 7_000, limit: 1_000_000), "1% · 7k")
        XCTAssertEqual(StatusRailView.readoutText(tokens: 132_000, limit: 200_000), "66% · 132k")
    }

    func testReadoutRoundsTokensToTheNearestThousand() {
        XCTAssertEqual(StatusRailView.readoutText(tokens: 1_500, limit: 1_000_000), "0% · 2k")
        XCTAssertEqual(StatusRailView.readoutText(tokens: 999_999, limit: 1_000_000), "100% · 1000k")
    }

    func testReadoutGuardsAgainstAZeroLimit() {
        XCTAssertEqual(StatusRailView.readoutText(tokens: 42, limit: 0), "0% · 0k")
    }

    // Fix round 1 — review findings.

    func testReadoutClampsNegativeTokensToZero() {
        // Percent was already clamped at 0; kTokens was not, and produced
        // "-1k" for a negative token count. Shouldn't happen in practice
        // (ContextMeter only ever sums non-negative usage fields), but the
        // formatter is a pure function — clamp defensively.
        XCTAssertEqual(StatusRailView.readoutText(tokens: -500, limit: 1_000_000), "0% · 0k")
    }

    func testReadoutClampsPercentButKeepsTheTruthfulTokenCountWhenOverLimit() {
        // Percent is clamped to 100 (display ceiling), but the absolute
        // token count stays truthful past the limit — this was already the
        // correct behavior, just untested until now.
        XCTAssertEqual(StatusRailView.readoutText(tokens: 1_500_000, limit: 1_000_000), "100% · 1500k")
    }
}
