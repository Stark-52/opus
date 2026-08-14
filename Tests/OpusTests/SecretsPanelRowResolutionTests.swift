// SecretsPanelRowResolutionTests — coverage for the one seam a mouse click
// and a keyboard action share when acting on a row in the secrets list:
// resolving WHICH secret a table row index refers to.
//
// The panel itself is AppKit and not independently testable (see
// SecretsPanel.swift's own header), but SecretsPanel.resolveRowName(at:
// filteredNames:) is pure — it exists specifically so the one place a
// click's row index turns into a secret name can be exercised without a
// live table view. Getting this wrong deletes (or reveals) a secret the
// user did not point at.

import XCTest
@testable import Opus

final class SecretsPanelRowResolutionTests: XCTestCase {
    func testResolvesTheNameAtTheGivenIndexInTheFilteredList() {
        // Simulates: the store holds more secrets than are currently
        // shown (a filter is active). Clicking the trash on visible row 1
        // must resolve to whichever secret is SECOND IN THE FILTERED
        // list — the only list a rendered row index can mean anything
        // against — not the second in some larger, unfiltered set.
        let filtered = ["demo-asc", "demo-resend", "demo-stripe"]
        XCTAssertEqual(SecretsPanel.resolveRowName(at: 0, filteredNames: filtered), "demo-asc")
        XCTAssertEqual(SecretsPanel.resolveRowName(at: 1, filteredNames: filtered), "demo-resend")
        XCTAssertEqual(SecretsPanel.resolveRowName(at: 2, filteredNames: filtered), "demo-stripe")
    }

    func testOutOfRangeIndexIsNilNotACrashOrAWrongGuess() {
        // A stale click racing a filter change (the list shrank between
        // the click and this resolving) must come back empty-handed, not
        // silently pick the nearest valid row.
        let filtered = ["demo-asc", "demo-resend"]
        XCTAssertNil(SecretsPanel.resolveRowName(at: 2, filteredNames: filtered))
        XCTAssertNil(SecretsPanel.resolveRowName(at: -1, filteredNames: filtered))
    }

    func testEmptyListResolvesNothing() {
        XCTAssertNil(SecretsPanel.resolveRowName(at: 0, filteredNames: []))
    }
}
