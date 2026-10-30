// RightDockResizeTests — a drawer slides over the terminal and the terminal
// takes its new width once. Every width the terminal passes through is a
// resize Claude Code redraws the whole screen for, and a redraw that lands
// while the width has moved on again leaves stray rows in the scrollback.

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
        drawer = NSView(frame: .zero)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(drawer)

        let terminalTrailing = terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let drawerTrailing = drawer.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let width = drawer.widthAnchor.constraint(equalToConstant: drawerWidth)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminalTrailing,
            drawer.topAnchor.constraint(equalTo: container.topAnchor),
            drawer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            drawerTrailing, width
        ])
        dock = RightDock(
            panels: [.reply: RightDock.Panel(view: drawer, trailing: drawerTrailing, width: width)],
            terminalTrailing: terminalTrailing,
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

    // The slide itself is AppKit's and does not run in a test; these hold
    // what the dock does around it: what moves during it, what after it.
    func testAnOpeningDrawerSlidesOverTheTerminalWhichNarrowsOnceItIsIn() {
        dock.show(.reply)
        XCTAssertEqual(drawer.frame.minX, 600, "the drawer is in")
        XCTAssertEqual(terminal.widths, [], "and the terminal has not moved yet")

        settle()
        XCTAssertEqual(terminal.widths, [600], "then one resize, straight to the narrower width")
    }

    func testAClosingDrawerUncoversATerminalAlreadyAtItsFullWidth() {
        dock.show(.reply)
        settle()
        terminal.widths = []

        dock.show(.none)
        XCTAssertEqual(terminal.widths, [900], "the terminal widens before the drawer leaves")
        settle()
        XCTAssertEqual(terminal.widths, [900])
    }

    func testDraggingTheDrawerEdgeResizesTheTerminalOnceWhenReleased() {
        dock.show(.reply)
        settle()
        terminal.widths = []

        for proposed in stride(from: 310, through: 400, by: 10) {
            dock.setWidth(CGFloat(proposed), for: .reply)
        }
        XCTAssertEqual(terminal.widths, [], "the drawer moves alone while the pointer does")
        XCTAssertEqual(drawer.frame.width, 400)

        dock.finishResize(for: .reply)
        XCTAssertEqual(terminal.widths, [500])
    }
}
