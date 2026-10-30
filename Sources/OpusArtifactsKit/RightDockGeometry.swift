// RightDockGeometry — the widths, and where a drawer's leading edge sits.
//
// TopRightButtonRow.drawerOpenShift stays where it is and stays -8: it
// does not depend on the occupant's width. The row is pinned to the edge of
// the uncovered terminal, which has already moved by the full width; the -8
// only compensates the 4pt overhang of the row's rightmost button.
//
// Width stopped being a constant when the drawers became resizable. What
// lives here now is the DEFAULT for each occupant plus the bounds a dragged
// edge is held inside; the live value is whatever the user last dragged to,
// which the app reads from preferences and hands to RightDock. This module
// stays free of UserDefaults so the arithmetic can be tested without one.

import Foundation
import CoreGraphics

public enum RightDockGeometry {
    public enum Occupant: Equatable, Sendable {
        case none
        case reply
        case artifacts
    }

    /// Below this a row's name, its parent directory and a 40pt thumbnail
    /// stop coexisting and the drawer is worse than closed.
    public static let minimumWidth: CGFloat = 220
    /// Above this the drawer is taking more of the window than the terminal
    /// it is meant to annotate.
    public static let maximumWidth: CGFloat = 640

    /// The width an occupant has until someone drags its edge.
    public static func defaultWidth(for occupant: Occupant) -> CGFloat {
        switch occupant {
        case .none: return 0
        /// Formatted prose with a copy gutter reads at around 60
        /// characters a line at 12pt, which needs this much.
        case .reply: return 380
        /// A 40pt thumbnail plus two lines of text does not fit in 260
        /// without truncating the parent directory to uselessness.
        case .artifacts: return 300
        }
    }

    /// Hold a proposed width inside the usable band. `.none` is not a
    /// drawer, so no drag can give it a width.
    public static func clampWidth(_ proposed: CGFloat, for occupant: Occupant) -> CGFloat {
        guard occupant != .none else { return 0 }
        return min(maximumWidth, max(minimumWidth, proposed))
    }

    /// Kept as the default-width spelling so callers that never resize (the
    /// drawer views' own `static let width`, the button-row tests) read the
    /// same value they always did.
    public static func width(for occupant: Occupant) -> CGFloat {
        defaultWidth(for: occupant)
    }

    /// The drawer's leading edge as a trailing constant from the container's
    /// trailing edge: the end of the part of the terminal it leaves uncovered.
    public static func edgeConstant(for occupant: Occupant) -> CGFloat {
        -defaultWidth(for: occupant)
    }

    /// The resizable path: the drawer covers exactly the width it currently
    /// has, whatever the user dragged it to.
    public static func edgeConstant(forWidth width: CGFloat) -> CGFloat {
        -width
    }

    public static func isOpen(_ occupant: Occupant) -> Bool { occupant != .none }
}
