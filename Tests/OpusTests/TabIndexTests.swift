import XCTest
@testable import Opus

final class TabIndexTests: XCTestCase {
    func testClosingTabBeforeActiveShiftsActiveDown() {
        // Tabs [0,1,2], active=2, close tab 0 → active must become 1 (same tab).
        XCTAssertEqual(TerminalContainerView.activeTabIndexAfterClosing(0, active: 2, newCount: 2), 1)
    }
    func testClosingActiveTabClampsToLast() {
        // Tabs [0,1], active=1, close tab 1 → active 0.
        XCTAssertEqual(TerminalContainerView.activeTabIndexAfterClosing(1, active: 1, newCount: 1), 0)
    }
    func testClosingAfterActiveKeepsActive() {
        XCTAssertEqual(TerminalContainerView.activeTabIndexAfterClosing(2, active: 0, newCount: 2), 0)
    }
    func testLastTabClosedGoesToZero() {
        XCTAssertEqual(TerminalContainerView.activeTabIndexAfterClosing(0, active: 0, newCount: 0), 0)
    }
}
