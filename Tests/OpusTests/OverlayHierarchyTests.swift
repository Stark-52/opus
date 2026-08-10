import XCTest
import SwiftTerm
@testable import Opus

final class OverlayHierarchyTests: XCTestCase {
    func testWalksUpThroughStackAndOverlayToTerminal() {
        // Replicates showDeadOverlay's hierarchy: terminal > overlay > stack > button
        let terminal = TerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let overlay = NSView(frame: terminal.bounds)
        let stack = NSStackView(views: [])
        let button = NSButton(title: "Start new session", target: nil, action: nil)
        stack.addArrangedSubview(button)
        overlay.addSubview(stack)
        terminal.addSubview(overlay)
        XCTAssertIdentical(TerminalContainerView.enclosingTerminalView(from: button), terminal)
    }
    func testReturnsNilWhenNoTerminalAncestor() {
        let lonely = NSButton(title: "x", target: nil, action: nil)
        XCTAssertNil(TerminalContainerView.enclosingTerminalView(from: lonely))
    }
}
