import XCTest
import AppKit
@testable import Opus

/// Two ways to place the same bars: a toolbar above the terminal and a
/// status bar below (A), or a single bar below (B). The terminal gets what
/// is left, with the panel's padding.
final class ChromeLayoutTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 900, height: 500)

    func testTheDefaultLayoutIsToolbarAndStatus() {
        XCTAssertEqual(ChromeLayout.resolve(nil), .toolbarAndStatus)
        XCTAssertEqual(ChromeLayout.resolve("garbage"), .toolbarAndStatus)
        XCTAssertEqual(ChromeLayout.resolve("singleBottomBar"), .singleBottomBar)
    }

    func testLayoutAReservesATopAndABottomBar() {
        let frames = ChromeArrangement.frames(layout: .toolbarAndStatus, bounds: bounds)
        XCTAssertEqual(frames.top, NSRect(x: 0, y: 468, width: 900, height: 32))
        XCTAssertEqual(frames.bottom, NSRect(x: 0, y: 0, width: 900, height: 22))
        XCTAssertEqual(frames.terminal, NSRect(x: 14, y: 28, width: 872, height: 434))
    }

    func testLayoutBReservesOneBottomBar() {
        let frames = ChromeArrangement.frames(layout: .singleBottomBar, bounds: bounds)
        XCTAssertNil(frames.top)
        XCTAssertEqual(frames.bottom, NSRect(x: 0, y: 0, width: 900, height: 32))
        XCTAssertEqual(frames.terminal, NSRect(x: 14, y: 38, width: 872, height: 448))
    }

    func testTheArrangementLaysTheViewsOutAsTheFramesSay() {
        let container = NSView(frame: bounds)
        let views = ChromeViews(top: ChromeBar(edge: .minY), bottom: ChromeBar(edge: .maxY),
                                tabs: ChromeTabStrip(frame: .zero), buttons: ChromeButtonBar(frame: .zero),
                                status: ChromeStatusView(frame: .zero), terminal: NSView())
        var active: [NSLayoutConstraint] = []
        for layout in [ChromeLayout.toolbarAndStatus, .singleBottomBar, .toolbarAndStatus] {
            NSLayoutConstraint.deactivate(active)
            active = ChromeArrangement.arrange(views, in: container, layout: layout)
            container.layoutSubtreeIfNeeded()
            let expected = ChromeArrangement.frames(layout: layout, bounds: bounds)
            XCTAssertEqual(views.terminal.frame, expected.terminal, "\(layout)")
            XCTAssertEqual(views.bottom.frame, expected.bottom, "\(layout)")
            XCTAssertEqual(views.top.isHidden, expected.top == nil, "\(layout)")
            XCTAssertTrue(views.tabs.superview === (layout == .toolbarAndStatus ? views.top : views.bottom))
        }
    }
}
