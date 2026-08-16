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
//
// The dock owns each drawer's OWN trailing constraint as well as the
// terminal's, because that is what makes the transition a slide rather
// than a sudden appearance. Both drawers are pinned to the container's
// right edge at a fixed width, so animating only the terminal's edge would
// shrink the terminal while the drawer popped into existence beside it.
// Animating both together moves the drawer in from off-screen at exactly
// the rate the terminal gives up the space.
//
// Deliberately NOT clipped. A parked drawer sits one full width past the
// container's trailing edge, and while closing it crosses that edge for the
// length of the animation. Setting `masksToBounds` on the container would
// contain that, and would also clip the Quick Terminal panel's
// open-in-Terminal button, which is pinned 4pt PAST the container's
// trailing edge on purpose (see TopRightButtonRow.openBase: the container's
// edge is the blur view's minus 14, and the button reproduces its historical
// position inside that padding). Trading a permanently clipped button for a
// 90ms cosmetic risk in a band that already hosts a button is the wrong way
// round.

import AppKit
import OpusArtifactsKit

final class RightDock {
    typealias Occupant = RightDockGeometry.Occupant

    /// One drawer, plus the constraint that parks it off the right edge.
    /// `trailing.constant` is 0 while showing and the drawer's own width
    /// while parked, so a parked drawer sits exactly one width to the right
    /// of the container and is invisible without relying on `isHidden`
    /// alone.
    struct Panel {
        let view: NSView
        let trailing: NSLayoutConstraint
    }

    private(set) var occupant: Occupant = .none

    private let panels: [Occupant: Panel]
    private let terminalTrailing: NSLayoutConstraint
    /// Runs the container's own layout pass. Called INSIDE the animation
    /// group, which is what turns the constraint changes into movement
    /// rather than a jump.
    private let layout: () -> Void
    /// Called after every change so the container can re-apply the button
    /// row and start or stop the occupant's timer. The container still owns
    /// both, because both reach into state this class deliberately does not
    /// know about.
    private let onChange: (Occupant) -> Void

    init(panels: [Occupant: Panel],
         terminalTrailing: NSLayoutConstraint,
         layout: @escaping () -> Void,
         onChange: @escaping (Occupant) -> Void) {
        self.panels = panels
        self.terminalTrailing = terminalTrailing
        self.layout = layout
        self.onChange = onChange
        // Start every drawer parked and hidden, so `occupant == .none` and
        // what is on screen agree by construction rather than by the
        // container remembering to set both.
        for (key, panel) in panels {
            panel.view.isHidden = true
            panel.trailing.constant = RightDockGeometry.width(for: key)
        }
    }

    /// Toggle: asking for the occupant that is already showing closes the
    /// dock, which is what every caller of the old toggleTodoDrawer meant.
    func toggle(_ requested: Occupant) {
        show(occupant == requested ? .none : requested)
    }

    func show(_ requested: Occupant) {
        guard requested != occupant else { return }
        occupant = requested

        // Unhide the incoming drawer BEFORE the animation starts: a hidden
        // view has nothing to slide. The outgoing one stays visible for the
        // whole animation and is hidden in the completion handler, which is
        // the mirror of the same reasoning.
        panels[requested]?.view.isHidden = false

        let opening = RightDockGeometry.isOpen(requested)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = opening
                ? PanelPresentation.appearDuration
                : PanelPresentation.dismissDuration
            context.timingFunction = CAMediaTimingFunction(
                name: opening ? .easeOut : .easeIn)
            context.allowsImplicitAnimation = true

            for (key, panel) in panels {
                panel.trailing.animator().constant =
                    key == requested ? 0 : RightDockGeometry.width(for: key)
            }
            terminalTrailing.animator().constant =
                RightDockGeometry.terminalTrailingConstant(for: requested)
            layout()
        }, completionHandler: { [weak self] in
            guard let self, self.occupant == requested else { return }
            // Guarded on the occupant still being what this animation was
            // for: a fast second toggle would otherwise let an older
            // completion hide the drawer that is now current.
            for (key, panel) in self.panels where key != requested {
                panel.view.isHidden = true
            }
        })

        onChange(requested)
    }
}
