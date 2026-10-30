// RightDockResizeTests — a drawer lies over the terminal, whose width never
// changes. On a new width Claude Code clears its screen and prints its live
// region again without clearing the scrollback, and the seam between the
// two layouts repeats or drops text. The edge of the uncovered part, which
// the top-right button row follows, moves with the drawer instead.

import XCTest
import AppKit
import OpusArtifactsKit
@testable import Opus

final class RightDockResizeTests: XCTestCase {
    /// The terminal's place in the layout, counting the widths it is given.
    private final class TerminalArea: NSView {
        var widths: [CGFloat] = []
        override func setFrameSize(_ newSize: NSSize) {
            if newSize.width != frame.width { widths.append(newSize.width) }
            super.setFrameSize(newSize)
        }
    }

    private var window: NSWindow!
    private var terminal: TerminalArea!
    private var uncovered: NSLayoutGuide!
    private var drawer: NSView!
    private var dock: RightDock!
    private var drawerWidth: CGFloat = 300
    /// The end of the slide in flight, called by the test when it chooses.
    private var finishSlide: (() -> Void)?

    override func setUp() {
        super.setUp()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = container

        terminal = TerminalArea(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        uncovered = NSLayoutGuide()
        container.addLayoutGuide(uncovered)
        drawer = NSView(frame: .zero)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(drawer)

        let edge = uncovered.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let drawerTrailing = drawer.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let width = drawer.widthAnchor.constraint(equalToConstant: drawerWidth)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            uncovered.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            uncovered.topAnchor.constraint(equalTo: terminal.topAnchor),
            uncovered.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
            edge,
            drawer.topAnchor.constraint(equalTo: container.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            drawerTrailing, width
        ])
        dock = RightDock(
            panels: [.reply: RightDock.Panel(view: drawer, trailing: drawerTrailing, width: width)],
            edge: edge,
            widthProvider: { [unowned self] occupant in occupant == .none ? 0 : self.drawerWidth },
            layout: { container.layoutSubtreeIfNeeded() },
            onChange: { _ in },
            animate: { [unowned self] _, changes, completion in
                changes()
                self.finishSlide = completion
            })
        container.layoutSubtreeIfNeeded()
        terminal.widths = []
    }

    override func tearDown() {
        window.close()
        window = nil
        super.tearDown()
    }

    private func settle() {
        finishSlide?()
        finishSlide = nil
    }

    // The slide itself is AppKit's and does not run in a test; the changes
    // made inside it are what it animates.
    func testAnOpeningDrawerLiesOverTheTerminalAndMovesTheEdgeWithIt() {
        dock.show(.reply)
        XCTAssertEqual(drawer.frame.minX, 600, "the drawer is in")
        XCTAssertEqual(uncovered.frame.maxX, 600, "the edge slid with it")
        settle()
        XCTAssertEqual(terminal.widths, [], "the terminal kept its width")
        XCTAssertEqual(drawer.isHidden, false)
    }

    func testAClosingDrawerGivesTheEdgeBackWithoutResizingTheTerminal() {
        dock.show(.reply)
        settle()

        dock.show(.none)
        XCTAssertEqual(uncovered.frame.maxX, 900)
        settle()
        XCTAssertEqual(terminal.widths, [])
        XCTAssertEqual(drawer.isHidden, true, "a parked drawer is hidden once it is out")
    }

    func testDraggingTheDrawerEdgeMovesTheUncoveredEdgeAlone() {
        dock.show(.reply)
        settle()

        for proposed in stride(from: 310, through: 400, by: 10) {
            dock.setWidth(CGFloat(proposed), for: .reply)
        }
        XCTAssertEqual(drawer.frame.width, 400)
        XCTAssertEqual(uncovered.frame.maxX, 500, "the edge follows the pointer")
        XCTAssertEqual(terminal.widths, [])
    }
}
