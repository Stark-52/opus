// ChromeBar — a band of the window reserved for controls, the way a macOS
// toolbar or status bar is: a faint fill and a hairline on the side that
// faces the terminal. Nothing in Opus floats over the terminal's text.

import AppKit

final class ChromeBar: NSView {
    /// The edge that faces the terminal: `.minY` (the bottom, this view is
    /// not flipped) for a bar above it, `.maxY` for a bar below it.
    private let edge: NSRectEdge

    init(edge: NSRectEdge) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        OpusTheme.cream(0.025).setFill()
        bounds.fill()
        // Not flipped: y = 0 is the bottom. A bar above the terminal draws
        // its hairline along its bottom, a bar below along its top.
        let lineY = edge == .minY ? bounds.minY : bounds.maxY - 1
        OpusTheme.cream(0.06).setFill()
        NSRect(x: bounds.minX, y: lineY, width: bounds.width, height: 1).fill()
    }
}
