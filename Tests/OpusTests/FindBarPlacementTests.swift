import XCTest
import AppKit
@testable import Opus

/// The Cmd+F bar opens inside the terminal, under the toolbar, never on it.
final class FindBarPlacementTests: XCTestCase {
    func testTheFindBarSitsInsideTheTerminalArea() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let area = NSView(frame: NSRect(x: 14, y: 28, width: 872, height: 434))
        container.addSubview(area)
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        NSLayoutConstraint.activate(TerminalContainerView.findBarConstraints(bar, terminalArea: area))
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(area.frame.contains(bar.frame), "\(bar.frame) outside \(area.frame)")
    }
}
