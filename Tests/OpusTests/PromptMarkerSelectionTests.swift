import XCTest
@testable import Opus

/// Cockpit (Lot 3, sticky-selection fix): TerminalContainerView.copySelectionToPasteboard
/// must not let a leftover Cmd+Up/Down prompt-jump selection ("❯ ", never
/// auto-cleared by SwiftTerm on streaming output) eat the Cmd+C interrupt.
/// Exercises the extracted static predicate directly — no live TerminalView
/// or selection needed.
final class PromptMarkerSelectionTests: XCTestCase {
    func testExactPromptMarkerIsRecognized() {
        XCTAssertTrue(TerminalContainerView.isPromptMarkerSelection("❯"))
    }

    func testPromptMarkerWithTrailingSpaceIsRecognized() {
        // This is the actual shape left selected by findPrevious/findNext("❯ ").
        XCTAssertTrue(TerminalContainerView.isPromptMarkerSelection("❯ "))
    }

    func testPromptMarkerWithSurroundingWhitespaceIsRecognized() {
        XCTAssertTrue(TerminalContainerView.isPromptMarkerSelection("  ❯ \n"))
    }

    func testRealUserSelectionIsNotRecognized() {
        XCTAssertFalse(TerminalContainerView.isPromptMarkerSelection("❯ npm install"))
        XCTAssertFalse(TerminalContainerView.isPromptMarkerSelection("some selected text"))
    }

    func testEmptyStringIsNotRecognizedByThisPredicateAlone() {
        // Empty selections are handled by copySelectionToPasteboard's own
        // !text.isEmpty check, not this predicate — verify the predicate
        // itself only matches the marker, not blank text.
        XCTAssertFalse(TerminalContainerView.isPromptMarkerSelection(""))
    }
}
