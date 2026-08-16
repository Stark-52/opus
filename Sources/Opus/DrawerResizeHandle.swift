// DrawerResizeHandle — the grabbable strip on a drawer's leading edge.
//
// Deliberately not part of either drawer view. Both drawers need the same
// behaviour, and the arithmetic it performs is about the CONTAINER's width,
// not the drawer's, so it belongs beside them rather than inside one of
// them. The container installs one per drawer and owns what a drag means.
//
// Invisible on purpose: it draws nothing and only announces itself through
// the resize cursor, the same way a window's own edges do. A visible grip
// would be a permanent 6pt stripe down a 300pt column to serve a gesture
// most sessions never use.

import AppKit

final class DrawerResizeHandle: NSView {
    /// How wide the grabbable strip is. Narrow enough not to steal clicks
    /// from the drawer's own content, wide enough to hit without aiming.
    static let thickness: CGFloat = 6

    /// Called continuously during the drag with the width the pointer
    /// implies. The container clamps and applies it; this view deliberately
    /// knows nothing about limits.
    private let proposeWidth: (CGFloat) -> Void
    /// Called once on mouse up, so the width is written to preferences at
    /// the end of a gesture rather than on every frame of it.
    private let commit: () -> Void

    init(proposeWidth: @escaping (CGFloat) -> Void, commit: @escaping () -> Void) {
        self.proposeWidth = proposeWidth
        self.commit = commit
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    /// The drawer can be dragged without first activating the window, same
    /// as every other control in this app's panels.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDragged(with event: NSEvent) {
        // Measured against the CONTAINER, not against this view: the drawer
        // is pinned to the container's trailing edge, so the width the user
        // is asking for is the distance from the pointer to that edge.
        // Using this view's own coordinates would drift by whatever the
        // handle had already moved.
        guard let container = superview else { return }
        let point = container.convert(event.locationInWindow, from: nil)
        proposeWidth(container.bounds.maxX - point.x)
    }

    override func mouseUp(with event: NSEvent) {
        commit()
    }
}
