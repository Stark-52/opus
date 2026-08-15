// RightDockGeometry — the widths, and the terminal's trailing constant.
//
// TopRightButtonRow.drawerOpenShift stays where it is and stays -8: it
// does not depend on the occupant's width. The row is pinned to
// terminalArea.trailingAnchor, which has already moved by the full width;
// the -8 only compensates the 4pt overhang of the row's rightmost button.

import Foundation
import CoreGraphics

public enum RightDockGeometry {
    public enum Occupant: Equatable, Sendable {
        case none
        case tasks
        case artifacts
    }

    public static func width(for occupant: Occupant) -> CGFloat {
        switch occupant {
        case .none: return 0
        /// Unchanged from v1.6. Users know where this edge is.
        case .tasks: return 260
        /// 40pt wider than tasks: a 40pt thumbnail plus two lines of text
        /// does not fit in 260 without truncating the parent directory to
        /// uselessness.
        case .artifacts: return 300
        }
    }

    public static func terminalTrailingConstant(for occupant: Occupant) -> CGFloat {
        -width(for: occupant)
    }

    public static func isOpen(_ occupant: Occupant) -> Bool { occupant != .none }
}
