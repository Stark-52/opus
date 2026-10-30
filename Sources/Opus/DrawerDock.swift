// DrawerDock — owner of the container's drawers: Copy on the left edge,
// Artifacts on the right.
//
// Before this existed, three things were welded to the Tasks drawer inside
// TerminalContainerView: the terminal area's trailing constraint, the
// top-right button row's shift, and the refresh timer's lifecycle. Adding
// a second drawer by copying that arithmetic would have copied the v1.6
// bug with it, where the row's members moved independently and ended up
// drawn inside the drawer.
//
// One occupant at a time. Opening one closes the other: two drawers over
// the terminal would cover more than half of it.
//
// A drawer lies over the terminal, whose width never changes: on a new
// width Claude Code clears its screen and prints its live region again,
// and since it never clears the scrollback, the seam between the two
// layouts repeats text (narrowing) or drops it (widening). The dock owns
// each drawer's outer-edge constraint.
//
// A drawer can also follow a swipe: `beginInteractive`, then a progress
// from 0 (parked) to 1 (in) per event, then `endInteractive` settles it one
// way or the other with the same slide a click gets.
//
// A parked drawer sits one full width past its side of the container and
// is hidden once the slide that parked it has ended.

import AppKit
import OpusArtifactsKit

final class DrawerDock {
    typealias Occupant = DrawerGeometry.Occupant

    /// One drawer and the constraint that pins its outer edge to the
    /// container's edge on its side. See `DrawerGeometry.offset`.
    struct Panel {
        let view: NSView
        let offset: NSLayoutConstraint
        /// The drawer's own width. Mutable because the inner edge is
        /// draggable; a parked drawer's offset has to follow it or a drawer
        /// resized while closed would reappear part-way on screen.
        let width: NSLayoutConstraint
        let side: DrawerSide
    }

    private(set) var occupant: Occupant = .none

    private let panels: [Occupant: Panel]
    /// Resolves an occupant's current width, which is a stored preference
    /// rather than a constant now that the edge can be dragged. Injected so
    /// this class stays free of UserDefaults.
    private let widthProvider: (Occupant) -> CGFloat
    /// Runs the container's own layout pass. Called INSIDE the animation
    /// group, which is what turns the constraint changes into movement
    /// rather than a jump.
    private let layout: () -> Void
    /// Called after every change so the container can light the open
    /// drawer's button and start or stop the occupant's timer. The container still owns
    /// both, because both reach into state this class deliberately does not
    /// know about.
    private let onChange: (Occupant) -> Void
    /// The drawer a swipe is moving, between `beginInteractive` and
    /// `endInteractive`.
    private var interactive: Occupant?

    /// Runs `changes` as the slide, then `completion` once it has ended.
    /// `opening` picks the duration and the easing.
    typealias Animator = (_ opening: Bool, _ changes: @escaping () -> Void,
                          _ completion: @escaping () -> Void) -> Void
    private let animate: Animator

    /// AppKit's slide: the constraint changes and the layout pass made
    /// inside the group are animated implicitly.
    static let slide: Animator = { opening, changes, completion in
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = opening
                ? PanelPresentation.appearDuration
                : PanelPresentation.dismissDuration
            context.timingFunction = CAMediaTimingFunction(
                name: opening ? .easeOut : .easeIn)
            context.allowsImplicitAnimation = true
            changes()
        }, completionHandler: completion)
    }

    init(panels: [Occupant: Panel],
         widthProvider: @escaping (Occupant) -> CGFloat,
         layout: @escaping () -> Void,
         onChange: @escaping (Occupant) -> Void,
         animate: @escaping Animator = DrawerDock.slide) {
        self.panels = panels
        self.widthProvider = widthProvider
        self.layout = layout
        self.onChange = onChange
        self.animate = animate
        // Start every drawer parked and hidden, so `occupant == .none` and
        // what is on screen agree by construction rather than by the
        // container remembering to set both.
        for (key, panel) in panels {
            panel.view.isHidden = true
            let w = widthProvider(key)
            panel.width.constant = w
            panel.offset.constant = DrawerGeometry.offset(width: w, side: panel.side, progress: 0)
        }
    }

    /// Apply a dragged width to the drawer immediately and without
    /// animation: a resize that eased toward the pointer would lag behind it
    /// and feel broken. Writing the value to preferences is the container's
    /// job, once, at the end of the gesture.
    func setWidth(_ proposed: CGFloat, for target: Occupant) {
        guard let panel = panels[target] else { return }
        let width = DrawerGeometry.clampWidth(proposed, for: target)
        panel.width.constant = width
        if target != occupant {
            panel.offset.constant = DrawerGeometry.offset(width: width, side: panel.side, progress: 0)
        }
        layout()
    }

    /// The width an occupant's drawer is currently laid out at, which after
    /// a drag is the clamped value rather than whatever the pointer asked
    /// for. The container reads this on mouse up so preferences store what
    /// is actually on screen.
    func currentWidth(for target: Occupant) -> CGFloat {
        panels[target]?.width.constant ?? 0
    }

    /// Toggle: asking for the occupant that is already showing closes the
    /// dock, which is what every caller of toggleReplyDrawer means.
    func toggle(_ requested: Occupant) {
        show(occupant == requested ? .none : requested)
    }

    func show(_ requested: Occupant) {
        guard requested != occupant else { return }
        settle(to: requested)
    }

    // MARK: Following a swipe

    /// A swipe starts moving `target`, opening it or, when it is the
    /// occupant, closing it.
    func beginInteractive(_ target: Occupant) {
        guard let panel = panels[target] else { return }
        interactive = target
        panel.view.isHidden = false
    }

    /// 0 parked, 1 fully in, without animation: the drawer is under the
    /// fingers.
    func setInteractiveProgress(_ progress: CGFloat) {
        guard let target = interactive, let panel = panels[target] else { return }
        panel.offset.constant = DrawerGeometry.offset(width: panel.width.constant, side: panel.side, progress: progress)
        layout()
    }

    /// The fingers lifted: slide the drawer the rest of the way in, or back
    /// out, from wherever the swipe left it.
    func endInteractive(open: Bool) {
        guard let target = interactive else { return }
        interactive = nil
        settle(to: open ? target : .none)
    }

    /// Slides every drawer to its place for `requested`, from wherever each
    /// one is, then hides the parked ones.
    private func settle(to requested: Occupant) {
        occupant = requested

        // Unhide the incoming drawer BEFORE the animation starts: a hidden
        // view has nothing to slide. The outgoing one stays visible for the
        // whole animation and is hidden in the completion handler, which is
        // the mirror of the same reasoning.
        panels[requested]?.view.isHidden = false

        animate(DrawerGeometry.isOpen(requested), { [self] in
            for (key, panel) in panels {
                panel.offset.constant = DrawerGeometry.offset(
                    width: widthProvider(key), side: panel.side, progress: key == requested ? 1 : 0)
            }
            layout()
        }, { [weak self] in
            // Guarded on the occupant still being what this animation was
            // for: a fast second toggle would otherwise let an older
            // completion hide the drawer that is now current.
            guard let self, self.occupant == requested else { return }
            for (key, panel) in self.panels where key != requested {
                panel.view.isHidden = true
            }
        })

        onChange(requested)
    }
}
