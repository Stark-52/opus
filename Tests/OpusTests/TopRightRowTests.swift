import XCTest
@testable import Opus

/// Palette fix round — the panel's top-right button row (↗ / pin / shield)
/// must travel as ONE unit when the Cmd+Shift+T todo drawer shrinks the
/// terminal area. In v1.6 only the shield moved (finding F2 pinned it to
/// `terminalArea.trailingAnchor`); the pin button stayed pinned to the panel's
/// own trailing edge and ended up floating inside the drawer's top-right
/// corner, looking like it belonged to the drawer.
final class TopRightRowTests: XCTestCase {
    private typealias Row = TerminalContainerView.TopRightButtonRow

    /// Container geometry: the container is inset 14pt from the panel's blur
    /// view on every side (QuickTerminalPanel's containerFrame), so a button
    /// whose offset from the container's trailing edge is `base` sits at
    /// `base - 14` from the blur's trailing edge.
    private let containerInset: CGFloat = 14

    func testClosedDrawerReproducesTheHistoricalGeometryExactly() {
        // No visual change in the common case: these are the literal blur
        // offsets the two buttons carried before they were repinned (-10 and
        // -72), and the shield's own -28 from the container edge (-42 from
        // the blur's).
        XCTAssertEqual(Row.trailingConstant(base: Row.openBase, drawerOpen: false) - containerInset, -10)
        XCTAssertEqual(Row.trailingConstant(base: Row.pinBase, drawerOpen: false) - containerInset, -72)
        XCTAssertEqual(Row.trailingConstant(base: Row.shieldBase, drawerOpen: false) - containerInset, -42)
    }

    func testOpenDrawerLeavesEveryButtonInsideTheShrunkenTerminalArea() {
        // The drawer's leading edge IS terminalArea's trailing edge while it
        // is open (buildSubviews pins the drawer flush to the container's
        // trailing edge and shrinks the terminal area by exactly its width),
        // so every button's own trailing edge has to land strictly LEFT of
        // that anchor — a negative constant. The ↗ button is the one that
        // fails without the row-wide shift: its natural offset is +4.
        for base in [Row.openBase, Row.shieldBase, Row.pinBase] {
            XCTAssertLessThan(Row.trailingConstant(base: base, drawerOpen: true), 0,
                              "button at base \(base) would draw on top of the drawer")
        }
        // Rightmost button clears the drawer by a visible margin, not by a hair.
        XCTAssertEqual(Row.trailingConstant(base: Row.openBase, drawerOpen: true), -4)
    }

    func testTheRowSlidesAsAUnitWithItsSpacingPreserved() {
        let bases = [Row.openBase, Row.shieldBase, Row.pinBase]
        let closed = bases.map { Row.trailingConstant(base: $0, drawerOpen: false) }
        let open = bases.map { Row.trailingConstant(base: $0, drawerOpen: true) }

        // Every button travels by the same amount — the v1.6 bug was exactly a
        // row whose members moved by different amounts (shield -260, pin 0).
        for (before, after) in zip(closed, open) {
            XCTAssertEqual(after - before, Row.drawerOpenShift)
        }
        // ...so the gaps between neighbours are untouched.
        let closedGaps = zip(closed, closed.dropFirst()).map { $0 - $1 }
        let openGaps = zip(open, open.dropFirst()).map { $0 - $1 }
        XCTAssertEqual(closedGaps, openGaps)
        XCTAssertFalse(closedGaps.isEmpty)
    }

    func testTheShiftMovesTheRowLeftNotRight() {
        XCTAssertLessThan(Row.drawerOpenShift, 0)
    }

    /// The mechanism the fix relies on: the pin/↗ buttons live in the panel's
    /// blur view, one level ABOVE the container, and are pinned to an anchor
    /// belonging to a view inside the container — across a frame-based
    /// (autoresizing-mask) intermediary. This replicates that hierarchy with
    /// plain views and checks the button really does follow the terminal area
    /// when the drawer's trailing constraint changes.
    func testAButtonInThePanelFollowsTheTerminalAreaAcrossTheFrameBasedContainer() {
        let blurWidth: CGFloat = 1000
        let blur = NSView(frame: NSRect(x: 0, y: 0, width: blurWidth, height: 400))

        // Same construction as QuickTerminalPanel: explicit frame + autoresizing
        // mask (translatesAutoresizingMaskIntoConstraints stays true), inset 14.
        let container = NSView(frame: NSRect(x: containerInset, y: containerInset,
                                             width: blurWidth - 2 * containerInset,
                                             height: 400 - 2 * containerInset))
        container.autoresizingMask = [.width, .height]
        blur.addSubview(container)

        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(area)
        let areaTrailing = area.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: container.topAnchor),
            area.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            area.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            areaTrailing
        ])

        let pin = NSButton(title: "", target: nil, action: nil)
        pin.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(pin)
        let pinTrailing = pin.trailingAnchor.constraint(
            equalTo: area.trailingAnchor,
            constant: Row.trailingConstant(base: Row.pinBase, drawerOpen: false))
        NSLayoutConstraint.activate([
            pin.topAnchor.constraint(equalTo: blur.topAnchor, constant: 16),
            pin.widthAnchor.constraint(equalToConstant: 24),
            pin.heightAnchor.constraint(equalToConstant: 22),
            pinTrailing
        ])
        blur.layoutSubtreeIfNeeded()

        // Drawer closed: the button is exactly where blur.trailing - 72 put it.
        XCTAssertEqual(pin.frame.maxX, blurWidth - 72, accuracy: 0.5)

        // Drawer open: terminal area shrinks, the button follows it, and the
        // row-wide shift is applied on top.
        areaTrailing.constant = -TodoDrawerView.width
        pinTrailing.constant = Row.trailingConstant(base: Row.pinBase, drawerOpen: true)
        blur.layoutSubtreeIfNeeded()

        let terminalAreaRight = blurWidth - containerInset - TodoDrawerView.width
        XCTAssertEqual(pin.frame.maxX,
                       terminalAreaRight + Row.trailingConstant(base: Row.pinBase, drawerOpen: true),
                       accuracy: 0.5)
        XCTAssertLessThan(pin.frame.maxX, terminalAreaRight,
                          "the pin button must sit inside the terminal area, not over the drawer")
    }
}
