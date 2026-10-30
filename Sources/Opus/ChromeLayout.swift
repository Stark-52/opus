// ChromeLayout: where the window's bars go, and the arrangement that puts
// them there.
//
// A, `toolbarAndStatus`: the tabs and buttons in a toolbar above the
// terminal, the memory and figures in a status bar below it. A cursor
// thrown at the top of the screen lands near the toolbar.
// B, `singleBottomBar`: everything in one bar below the terminal, nothing
// above the text being read.
//
// The same views serve both: the arrangement moves the tabs and buttons to
// the right bar and returns the constraints it activated, which the caller
// deactivates before the next change.

import AppKit

enum ChromeLayout: String, CaseIterable {
    case toolbarAndStatus, singleBottomBar

    /// A stored value, or A when there is none or it is unknown.
    static func resolve(_ raw: String?) -> ChromeLayout {
        raw.flatMap(ChromeLayout.init(rawValue:)) ?? .toolbarAndStatus
    }

    var title: String {
        switch self {
        case .toolbarAndStatus: return "Barre d'outils en haut, état en bas"
        case .singleBottomBar: return "Une seule barre en bas"
        }
    }
}

struct ChromeViews {
    let top: ChromeBar
    let bottom: ChromeBar
    let tabs: ChromeTabStrip
    let buttons: ChromeButtonBar
    let status: ChromeStatusView
    let terminal: NSView
}

enum ChromeArrangement {
    static let toolbarHeight: CGFloat = 32
    static let statusBarHeight: CGFloat = 22
    static let singleBarHeight: CGFloat = 32
    /// Between a bar and the terminal.
    static let gap: CGFloat = 6
    /// The panel's padding around the terminal where no bar is.
    static let padding = OpusTheme.insetPanel

    /// Where the bars and the terminal land in `bounds` (not flipped: y = 0
    /// is the bottom). `top` is nil when the layout has no top bar.
    static func frames(layout: ChromeLayout, bounds: NSRect) -> (top: NSRect?, bottom: NSRect, terminal: NSRect) {
        let width = bounds.width
        switch layout {
        case .toolbarAndStatus:
            let top = NSRect(x: 0, y: bounds.height - toolbarHeight, width: width, height: toolbarHeight)
            let bottom = NSRect(x: 0, y: 0, width: width, height: statusBarHeight)
            let terminal = NSRect(x: padding, y: bottom.maxY + gap, width: width - 2 * padding,
                                  height: top.minY - gap - (bottom.maxY + gap))
            return (top, bottom, terminal)
        case .singleBottomBar:
            let bottom = NSRect(x: 0, y: 0, width: width, height: singleBarHeight)
            let terminal = NSRect(x: padding, y: bottom.maxY + gap, width: width - 2 * padding,
                                  height: bounds.height - padding - (bottom.maxY + gap))
            return (nil, bottom, terminal)
        }
    }

    /// Puts each view in its bar for `layout` and activates the constraints
    /// that match `frames`, returned for the caller to deactivate next time.
    static func arrange(_ v: ChromeViews, in container: NSView, layout: ChromeLayout) -> [NSLayoutConstraint] {
        for view in [v.terminal, v.top, v.bottom] where view.superview !== container {
            container.addSubview(view)
        }
        let isA = layout == .toolbarAndStatus
        let bar = isA ? v.top : v.bottom
        for (view, parent) in [(v.tabs as NSView, bar), (v.buttons, bar), (v.status, v.bottom)]
        where view.superview !== parent {
            view.removeFromSuperview()
            parent.addSubview(view)
        }
        for view in [v.top, v.bottom, v.tabs, v.buttons, v.status, v.terminal] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        v.top.isHidden = !isA
        v.status.showsMemory = isA
        // Alone with the buttons (A), the tabs take the toolbar's slack; next
        // to the figures (B) they keep their natural width and give way first.
        v.tabs.setContentHuggingPriority(isA ? .defaultLow : .defaultHigh, for: .horizontal)

        var constraints = [
            v.top.topAnchor.constraint(equalTo: container.topAnchor),
            v.top.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.top.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.top.heightAnchor.constraint(equalToConstant: isA ? toolbarHeight : 0),

            v.bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            v.bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.bottom.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.bottom.heightAnchor.constraint(equalToConstant: isA ? statusBarHeight : singleBarHeight),

            v.terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            v.terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            v.terminal.topAnchor.constraint(equalTo: v.top.bottomAnchor, constant: isA ? gap : padding),
            v.terminal.bottomAnchor.constraint(equalTo: v.bottom.topAnchor, constant: -gap),

            v.tabs.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: padding),
            v.tabs.topAnchor.constraint(equalTo: bar.topAnchor),
            v.tabs.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            v.buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            v.buttons.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            v.status.centerYAnchor.constraint(equalTo: v.bottom.centerYAnchor),
        ]
        if isA {
            constraints += [
                v.tabs.trailingAnchor.constraint(equalTo: v.buttons.leadingAnchor, constant: -12),
                v.status.leadingAnchor.constraint(equalTo: v.bottom.leadingAnchor, constant: padding),
                v.status.trailingAnchor.constraint(equalTo: v.bottom.trailingAnchor, constant: -padding),
            ]
        } else {
            // The tabs keep their natural width (they hug it) and give way
            // first when the bar is short; the figures fill the middle.
            constraints += [
                v.status.leadingAnchor.constraint(equalTo: v.tabs.trailingAnchor, constant: 12),
                v.status.trailingAnchor.constraint(equalTo: v.buttons.leadingAnchor, constant: -12),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return constraints
    }
}
