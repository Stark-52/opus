// DrawerGeometry — the drawers' widths, sides and offsets.
//
// Width stopped being a constant when the drawers became resizable. What
// lives here now is the DEFAULT for each occupant plus the bounds a dragged
// edge is held inside; the live value is whatever the user last dragged to,
// which the app reads from preferences and hands to DrawerDock. This module
// stays free of UserDefaults so the arithmetic can be tested without one.

import Foundation
import CoreGraphics

public enum DrawerSide: Sendable {
    case leading, trailing
}

public enum DrawerGeometry {
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

    public static func isOpen(_ occupant: Occupant) -> Bool { occupant != .none }

    /// Copy comes in from the left, where a swipe to the right pulls it;
    /// Artifacts from the right.
    public static func side(for occupant: Occupant) -> DrawerSide {
        occupant == .reply ? .leading : .trailing
    }

    /// The constant of the constraint that pins a drawer's outer edge to the
    /// container's edge on its side: 0 fully in, one width out (negative on
    /// the left) fully parked, and in between for a drawer following a swipe.
    public static func offset(width: CGFloat, side: DrawerSide, progress: CGFloat) -> CGFloat {
        let parked = side == .trailing ? width : -width
        return parked * (1 - min(1, max(0, progress)))
    }
}
