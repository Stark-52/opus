// ChromeTabStrip: the window's tabs, compact and aligned left like Safari's:
// each as wide as its title within a floor and a ceiling, the activity dot
// before the title, a "+" after the last. Shown with a single tab too, whose
// title then reads as the window's.

import AppKit

final class ChromeTabStrip: NSView {
    static let minTabWidth: CGFloat = 80
    static let maxTabWidth: CGFloat = 220
    static let tabGap: CGFloat = 4
    static let plusWidth: CGFloat = 24
    /// Dot, its gap, and the horizontal padding around the title.
    private static let tabChrome: CGFloat = OpusTheme.dotSize + 6 + 2 * 10
    static let titleFont = NSFont.systemFont(ofSize: 11.5)

    var titles: [String] = [] {
        didSet {
            needsDisplay = true
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }
    /// One per tab, same index space as `titles`; missing entries draw no dot.
    var states: [PaneActivity] = [] { didSet { needsDisplay = true } }
    var activeIndex = 0 {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }
    var onSwitch: ((Int) -> Void)?
    var onNewTab: (() -> Void)?

    private var hoveredIndex: Int? { didSet { if hoveredIndex != oldValue { needsDisplay = true } } }

    /// Each title's natural width held between the floor and the ceiling;
    /// when they do not all fit in `available` (the "+" included), every tab
    /// shrinks toward the same share, never below the floor. What still does
    /// not fit is cut by the strip itself.
    static func tabWidths(titles: [String], font: NSFont, available: CGFloat) -> [CGFloat] {
        let natural = titles.map { title -> CGFloat in
            let text = ceil((title as NSString).size(withAttributes: [.font: font]).width)
            return min(maxTabWidth, max(minTabWidth, text + tabChrome))
        }
        let gaps = CGFloat(max(0, titles.count - 1)) * tabGap
        let room = available - plusWidth - tabGap - gaps
        guard natural.reduce(0, +) > room, !titles.isEmpty else { return natural }
        let share = max(minTabWidth, floor(room / CGFloat(titles.count)))
        return natural.map { min($0, share) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // The first to give way when a bar is short; how much it hugs its
        // natural width is the layout's call (see ChromeArrangement).
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Never draw past its band, whatever AppKit's default for the SDK.
        if #available(macOS 14, *) { clipsToBounds = true }
    }

    /// Every tab at its natural width, plus the "+".
    override var intrinsicContentSize: NSSize {
        let widths = Self.tabWidths(titles: titles, font: Self.titleFont, available: .greatestFiniteMagnitude)
        let width = widths.reduce(0, +) + CGFloat(widths.count) * Self.tabGap + Self.plusWidth
        return NSSize(width: width, height: NSView.noIntrinsicMetric)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    /// Tab rects left to right, then the "+" rect, vertically centered in
    /// `height`. When the tabs do not fit, the "+" holds the right edge and
    /// the row slides left just enough for the active tab to end before it;
    /// the tabs past either end are cut by `draw`.
    static func tabFrames(titles: [String], activeIndex: Int, font: NSFont,
                          available: CGFloat, height: CGFloat) -> (tabs: [NSRect], plus: NSRect) {
        let widths = tabWidths(titles: titles, font: font, available: available)
        let tabHeight: CGFloat = 24
        let y = floor((height - tabHeight) / 2)
        var x: CGFloat = 0
        var tabs: [NSRect] = []
        for width in widths {
            tabs.append(NSRect(x: x, y: y, width: width, height: tabHeight))
            x += width + tabGap
        }
        let room = available - plusWidth - tabGap
        guard let last = tabs.last, last.maxX > room else {
            return (tabs, NSRect(x: x, y: y, width: plusWidth, height: tabHeight))
        }
        let active = tabs.indices.contains(activeIndex) ? tabs[activeIndex] : last
        let shift = max(0, active.maxX - room)
        return (tabs.map { $0.offsetBy(dx: -shift, dy: 0) },
                NSRect(x: available - plusWidth, y: y, width: plusWidth, height: tabHeight))
    }

    /// A tab's tooltip: its title, and the shortcut that reaches it when it
    /// has one (Cmd+1 to Cmd+9).
    static func toolTip(index: Int, title: String) -> String {
        index < 9 ? "\(title) (Cmd+\(index + 1))" : title
    }

    override func layout() {
        super.layout()
        removeAllToolTips()
        let (tabs, plus) = layoutRects()
        for (index, rect) in tabs.enumerated() where rect.maxX > 0 && rect.minX < tabRoom {
            addToolTip(rect.intersection(NSRect(x: 0, y: 0, width: tabRoom, height: bounds.height)),
                       owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
        if plus.maxX <= bounds.width {
            addToolTip(plus, owner: self, userData: nil)
        }
    }

    /// Where the tabs may draw: left of the "+".
    private var tabRoom: CGFloat { max(0, bounds.width - Self.plusWidth - Self.tabGap) }

    private func layoutRects() -> (tabs: [NSRect], plus: NSRect) {
        Self.tabFrames(titles: titles, activeIndex: activeIndex, font: Self.titleFont,
                       available: bounds.width, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let (tabs, plus) = layoutRects()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: tabRoom, height: bounds.height).clip()
        for (index, rect) in tabs.enumerated() where rect.maxX > 0 && rect.minX < tabRoom {
            let isActive = index == activeIndex
            if isActive || index == hoveredIndex {
                (isActive ? OpusTheme.cream(0.09) : OpusTheme.cream(0.05)).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            var textX = rect.minX + 10
            if index < states.count, let dotColor = OpusTheme.activityColor(states[index]) {
                let dot = NSRect(x: textX, y: rect.midY - OpusTheme.dotSize / 2,
                                 width: OpusTheme.dotSize, height: OpusTheme.dotSize)
                dotColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            textX += OpusTheme.dotSize + 6
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont,
                .foregroundColor: isActive ? OpusTheme.cream(0.95) : OpusTheme.cream(0.55),
                .paragraphStyle: para,
            ]
            let title = titles[index].isEmpty ? "Claude" : titles[index]
            let textHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender)
            (title as NSString).draw(
                with: NSRect(x: textX, y: rect.midY - textHeight / 2, width: rect.maxX - 10 - textX, height: textHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        if plus.maxX <= bounds.width {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .light),
                .foregroundColor: hoveredIndex == -1 ? OpusTheme.cream(0.9) : OpusTheme.cream(0.45),
            ]
            let size = ("+" as NSString).size(withAttributes: attrs)
            ("+" as NSString).draw(at: NSPoint(x: plus.midX - size.width / 2, y: plus.midY - size.height / 2),
                                   withAttributes: attrs)
        }
    }

    /// The tab index under `point`, -1 for the "+", nil for empty space.
    private func hit(_ point: NSPoint) -> Int? {
        let (tabs, plus) = layoutRects()
        if point.x < tabRoom, let index = tabs.firstIndex(where: { $0.contains(point) }) { return index }
        return plus.contains(point) && plus.maxX <= bounds.width ? -1 : nil
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredIndex = hit(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoveredIndex = nil }

    override func mouseDown(with event: NSEvent) {
        guard let index = hit(convert(event.locationInWindow, from: nil)) else { return }
        if index == -1 { onNewTab?() } else if index != activeIndex { onSwitch?(index) }
    }
}

extension ChromeTabStrip: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "Nouvel onglet (Cmd+T)" }
        let index = Int(bitPattern: data) - 1
        guard titles.indices.contains(index) else { return "" }
        return Self.toolTip(index: index, title: titles[index].isEmpty ? "Claude" : titles[index])
    }
}
