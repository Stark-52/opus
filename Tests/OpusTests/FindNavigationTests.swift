import XCTest
@testable import Opus

/// v1.4.2 task-review Finding 1-3 — exercises the PURE helpers extracted out
/// of `TerminalContainerView.navigateFind`'s async/caching rework, without a
/// live TerminalView/SwiftTerm buffer:
///  - `resolveMatchDisplay` (Finding 2's safety guard: a jump SwiftTerm
///    found — `found == true` — but our own harvest-based count came back
///    0 must never display "no match", since that would contradict a match
///    the user can see highlighted on screen. Also covers the ordinary
///    wrap-around index advancement, unchanged from the pre-review logic.)
///  - `harvestCap` (Finding 3: the harvest cap now tracks the user's
///    configured scrollback instead of a hardcoded 50_000).
final class FindNavigationTests: XCTestCase {
    // MARK: resolveMatchDisplay — not found

    func testNotFoundAlwaysShowsNoMatchRegardlessOfTotal() {
        // `found == false` is unambiguous — SwiftTerm itself found nothing —
        // so this must say "no match" even if a stale/cached total was
        // passed in.
        let result = TerminalContainerView.resolveMatchDisplay(found: false, total: 7, previousIndex: 3, direction: .down)
        XCTAssertEqual(result.text, "no match")
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.total, 0)
    }

    // MARK: resolveMatchDisplay — Finding 2 safety guard

    func testFoundWithZeroTotalShowsUnknownNotNoMatch() {
        // The worst case this finding exists for: SwiftTerm highlighted a
        // match (found == true) but our own row-by-row harvest can't see it
        // (a match straddling a soft-wrap boundary — BufferLine.isWrapped
        // isn't public, see resolveMatchDisplay's doc comment). Must NOT
        // say "no match" — that would contradict what's on screen.
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 0, previousIndex: 0, direction: .up)
        XCTAssertEqual(result.text, "…")
        XCTAssertNotEqual(result.text, "no match")
        XCTAssertEqual(result.index, 0)
        XCTAssertEqual(result.total, 0)
    }

    func testFoundWithZeroTotalIsUnknownForBothDirections() {
        let up = TerminalContainerView.resolveMatchDisplay(found: true, total: 0, previousIndex: 2, direction: .up)
        let down = TerminalContainerView.resolveMatchDisplay(found: true, total: 0, previousIndex: 2, direction: .down)
        XCTAssertEqual(up.text, "…")
        XCTAssertEqual(down.text, "…")
    }

    // MARK: resolveMatchDisplay — ordinary index advancement (unchanged semantics)

    func testFreshSearchUpLandsOnFirstMatch() {
        // previousIndex 0 (fresh term) + .up: 0 >= total is false → +1.
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 5, previousIndex: 0, direction: .up)
        XCTAssertEqual(result.text, "1 / 5")
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.total, 5)
    }

    func testFreshSearchDownLandsOnLastMatch() {
        // previousIndex 0 (fresh term) + .down: 0 <= 1 is true → total.
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 5, previousIndex: 0, direction: .down)
        XCTAssertEqual(result.text, "5 / 5")
        XCTAssertEqual(result.index, 5)
    }

    func testUpWrapsFromLastToFirst() {
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 3, previousIndex: 3, direction: .up)
        XCTAssertEqual(result.index, 1)
        XCTAssertEqual(result.text, "1 / 3")
    }

    func testDownWrapsFromFirstToLast() {
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 3, previousIndex: 1, direction: .down)
        XCTAssertEqual(result.index, 3)
        XCTAssertEqual(result.text, "3 / 3")
    }

    func testUpAdvancesByOne() {
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 5, previousIndex: 2, direction: .up)
        XCTAssertEqual(result.index, 3)
        XCTAssertEqual(result.text, "3 / 5")
    }

    func testDownRetreatsByOne() {
        let result = TerminalContainerView.resolveMatchDisplay(found: true, total: 5, previousIndex: 3, direction: .down)
        XCTAssertEqual(result.index, 2)
        XCTAssertEqual(result.text, "2 / 5")
    }

    // MARK: scheduledCountPlaceholder — v1.5 re-review of 43853ca

    func testScheduledCountPlaceholderMatchesFoundWithUnknownTotal() {
        // The label `navigateFind` paints the instant a jump succeeds but
        // its count is still in flight (scheduleMatchCount) must be
        // byte-for-byte the SAME text `resolveMatchDisplay` returns for its
        // found-but-total-unknown case — otherwise a stale "no match" from a
        // PRIOR failed search could survive the ~84ms until the background
        // count lands, contradicting a highlight already visible on screen.
        // Checked across both directions and several previousIndex values
        // so the two can never silently drift apart.
        for direction: TerminalContainerView.FindDirection in [.up, .down] {
            for previousIndex in [0, 1, 4] {
                let placeholder = TerminalContainerView.scheduledCountPlaceholder(previousIndex: previousIndex, direction: direction)
                let expected = TerminalContainerView.resolveMatchDisplay(found: true, total: 0, previousIndex: previousIndex, direction: direction).text
                XCTAssertEqual(placeholder, expected)
                XCTAssertEqual(placeholder, "…")
                XCTAssertNotEqual(placeholder, "no match")
            }
        }
    }

    // MARK: harvestCap — Finding 3

    func testHarvestCapTracksScrollbackWithHeadroom() {
        XCTAssertEqual(TerminalContainerView.harvestCap(scrollbackLines: 10_000), 11_000)
    }

    func testHarvestCapAtSmallScrollback() {
        XCTAssertEqual(TerminalContainerView.harvestCap(scrollbackLines: 1_000), 2_000)
    }

    func testHarvestCapIsBoundedAtAbsoluteCeilingEvenAtMaxScrollback() {
        // OpusPreferences.scrollbackLines clamps to 200_000 max; +1_000
        // headroom must not push the cap past the 200_000 absolute ceiling.
        XCTAssertEqual(TerminalContainerView.harvestCap(scrollbackLines: 200_000), 200_000)
    }

    func testHarvestCapNeverExceedsAbsoluteCeilingEvenForAnOutOfRangeInput() {
        // Defense in depth: even if a caller passed something already past
        // the preference's own clamp, the cap itself still bounds worst-case
        // work at 200_000.
        XCTAssertEqual(TerminalContainerView.harvestCap(scrollbackLines: 5_000_000), 200_000)
    }
}
