// DrawerDockTests — Copy on the left edge, Artifacts on the right, one at a
// time, lying over a terminal whose width never changes. On a new width
// Claude Code reprints its live region without clearing the scrollback, and
// the seam between the two layouts repeats or drops text.

import XCTest
import AppKit
import OpusArtifactsKit
@testable import Opus

final class DrawerDockTests: XCTestCase {
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
    private var copyDrawer: NSView!
    private var artifactsDrawer: NSView!
    private var dock: DrawerDock!
    private let drawerWidth: CGFloat = 300
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
        copyDrawer = NSView(frame: .zero)
        artifactsDrawer = NSView(frame: .zero)
        let uncovered = NSLayoutGuide()
        container.addLayoutGuide(uncovered)
        for view in [terminal!, copyDrawer!, artifactsDrawer!] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        let edge = uncovered.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let copyOffset = copyDrawer.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        let artifactsOffset = artifactsDrawer.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        let copyWidth = copyDrawer.widthAnchor.constraint(equalToConstant: drawerWidth)
        let artifactsWidth = artifactsDrawer.widthAnchor.constraint(equalToConstant: drawerWidth)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            uncovered.leadingAnchor.constraint(equalTo: terminal.leadingAnchor),
            uncovered.topAnchor.constraint(equalTo: terminal.topAnchor),
            uncovered.bottomAnchor.constraint(equalTo: terminal.bottomAnchor),
            edge,
            copyDrawer.topAnchor.constraint(equalTo: container.topAnchor),
            copyDrawer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            artifactsDrawer.topAnchor.constraint(equalTo: container.topAnchor),
            artifactsDrawer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            copyOffset, artifactsOffset, copyWidth, artifactsWidth,
        ])
        dock = DrawerDock(
            panels: [
                .reply: DrawerDock.Panel(view: copyDrawer, offset: copyOffset, width: copyWidth, side: .leading),
                .artifacts: DrawerDock.Panel(view: artifactsDrawer, offset: artifactsOffset,
                                             width: artifactsWidth, side: .trailing),
            ],
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

    func testTheCopyDrawerOpensFromTheLeft() {
        XCTAssertEqual(copyDrawer.frame.minX, -300, "parked one width off the left edge")
        dock.show(.reply)
        XCTAssertEqual(copyDrawer.frame.minX, 0)
        settle()
        XCTAssertFalse(copyDrawer.isHidden)
    }

    func testTheArtifactsDrawerStillOpensFromTheRight() {
        XCTAssertEqual(artifactsDrawer.frame.minX, 900)
        dock.show(.artifacts)
        XCTAssertEqual(artifactsDrawer.frame.minX, 600)
    }

    func testOneDrawerAtATimeSwaps() {
        dock.show(.reply)
        settle()
        dock.show(.artifacts)
        XCTAssertEqual(copyDrawer.frame.minX, -300)
        XCTAssertEqual(artifactsDrawer.frame.minX, 600)
        settle()
        XCTAssertTrue(copyDrawer.isHidden)
        XCTAssertEqual(dock.occupant, .artifacts)
    }

    func testInteractiveProgressPlacesTheDrawerPartWay() {
        dock.beginInteractive(.reply)
        dock.setInteractiveProgress(0.5)
        XCTAssertEqual(copyDrawer.frame.minX, -150)
        XCTAssertFalse(copyDrawer.isHidden)
        XCTAssertNil(finishSlide, "following the fingers is not animated")
    }

    func testEndingInteractiveOpenSettlesItOpen() {
        dock.beginInteractive(.reply)
        dock.setInteractiveProgress(0.4)
        dock.endInteractive(open: true)
        XCTAssertEqual(copyDrawer.frame.minX, 0)
        settle()
        XCTAssertEqual(dock.occupant, .reply)
    }

    func testEndingInteractiveClosedParksAndHidesIt() {
        dock.beginInteractive(.artifacts)
        dock.setInteractiveProgress(0.2)
        dock.endInteractive(open: false)
        XCTAssertEqual(artifactsDrawer.frame.minX, 900)
        settle()
        XCTAssertTrue(artifactsDrawer.isHidden)
        XCTAssertEqual(dock.occupant, .none)
    }

    func testClosingAnOpenDrawerInteractively() {
        dock.show(.artifacts)
        settle()
        dock.beginInteractive(.artifacts)
        dock.setInteractiveProgress(0.5)
        XCTAssertEqual(artifactsDrawer.frame.minX, 750)
        dock.endInteractive(open: false)
        settle()
        XCTAssertEqual(dock.occupant, .none)
        XCTAssertTrue(artifactsDrawer.isHidden)
    }

    func testNoDrawerEverResizesTheTerminal() {
        dock.show(.reply); settle()
        dock.show(.artifacts); settle()
        dock.beginInteractive(.artifacts); dock.setInteractiveProgress(0.3); dock.endInteractive(open: false); settle()
        XCTAssertEqual(terminal.widths, [])
    }
}
