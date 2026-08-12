// OpusTheme — the single source of truth for Opus's colors and metrics.
//
// Three feature batches each hardcoded their own cream/cyan values and corner
// radii, so "the same" color drifted between views and no color carried a
// stable meaning. One token set fixes both: every view reads from here, and
// each color means exactly one thing (see contextColor/activityColor).

import AppKit

enum OpusTheme {
    // MARK: Colors

    /// Warm off-white used for every piece of text and every resting control.
    static let cream = NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 1.0)
    static func cream(_ alpha: CGFloat) -> NSColor {
        NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: alpha)
    }

    /// Brand icy-cyan (the Opus icon's core glow): nominal state, active controls.
    static let cyan = NSColor(red: 0.60, green: 0.85, blue: 0.95, alpha: 1.0)
    /// Attention, not yet a problem.
    static let amber = NSColor(red: 0.95, green: 0.75, blue: 0.35, alpha: 1.0)
    /// Action required.
    static let red = NSColor(red: 0.95, green: 0.45, blue: 0.45, alpha: 1.0)
    /// Finished.
    static let green = NSColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 1.0)

    /// Opaque backing for floating surfaces (palette, find bar).
    static let panelBackground = NSColor(calibratedWhite: 0.08, alpha: 0.97)

    /// Dark text painted on top of the terminal caret block (SwiftTerm's
    /// `caretTextColor`) so the character under the caret stays legible
    /// against the light `caretColor` fill. Not part of the cream/cyan/
    /// amber/red/green semantic set above — this is a fixed contrast pair
    /// with `cream`, not a status color — so it gets its own token rather
    /// than overloading one of those meanings. Value unchanged from the
    /// pre-token literal in `styleTerminal`.
    static let caretText = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)

    // MARK: Metrics

    static let radiusPanel: CGFloat = 14
    static let radiusControl: CGFloat = 8
    static let insetPanel: CGFloat = 14
    static let controlGap: CGFloat = 6
    static let railHeight: CGFloat = 3
    static let dotSize: CGFloat = 6

    // MARK: Semantics

    /// Context burn: nominal through 70%, attention through 85%, then critical.
    static func contextColor(fraction: CGFloat) -> NSColor {
        if fraction <= 0.70 { return cyan }
        if fraction <= 0.85 { return amber }
        return red
    }

    /// Activity indicator color mapping to PaneActivity states.
    /// Returns nil for .idle to indicate the dot should not be shown.
    static func activityColor(_ activity: PaneActivity) -> NSColor? {
        switch activity {
        case .working:
            return cyan
        case .needsInput:
            return red
        case .done:
            return green
        case .idle:
            return nil
        }
    }
}
