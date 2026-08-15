// RightDock — owner of the container's right edge.
//
// Before this existed, three things were welded to the Tasks drawer inside
// TerminalContainerView: the terminal area's trailing constraint, the
// top-right button row's shift, and the refresh timer's lifecycle. Adding
// a second drawer by copying that arithmetic would have copied the v1.6
// bug with it, where the row's members moved independently and ended up
// drawn inside the drawer.
//
// One occupant at a time. Opening one closes the other, so the terminal
// only ever pays for one drawer's width.

import AppKit
import OpusArtifactsKit

final class RightDock {
    typealias Occupant = RightDockGeometry.Occupant

    private(set) var occupant: Occupant = .none

    private let views: [Occupant: NSView]
    private let terminalTrailing: NSLayoutConstraint
    /// Called after every change so the container can re-apply the button
    /// row and start or stop the occupant's timer. The container still owns
    /// both, because both reach into state this class deliberately does not
    /// know about.
    private let onChange: (Occupant) -> Void

    init(views: [Occupant: NSView],
         terminalTrailing: NSLayoutConstraint,
         onChange: @escaping (Occupant) -> Void) {
        self.views = views
        self.terminalTrailing = terminalTrailing
        self.onChange = onChange
        for view in views.values { view.isHidden = true }
    }

    /// Toggle: asking for the occupant that is already showing closes the
    /// dock, which is what every caller of the old toggleTodoDrawer meant.
    func toggle(_ requested: Occupant) {
        show(occupant == requested ? .none : requested)
    }

    func show(_ requested: Occupant) {
        guard requested != occupant else { return }
        occupant = requested
        for (key, view) in views { view.isHidden = key != requested }
        terminalTrailing.constant = RightDockGeometry.terminalTrailingConstant(for: requested)
        onChange(requested)
    }
}
