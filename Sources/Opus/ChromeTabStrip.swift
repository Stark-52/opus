// ChromeTabStrip: the window's tabs, compact and aligned left like Safari's:
// each as wide as its title within a floor and a ceiling, the Claude avatar
// (ClaudeAvatar) before the title, a "+" after the last. Shown with a single tab too, whose
// title then reads as the window's.

import AppKit

final class ChromeTabStrip: NSView {
    static let minTabWidth: CGFloat = 80
    static let maxTabWidth: CGFloat = 220
    static let tabGap: CGFloat = 4
    static let plusWidth: CGFloat = 24
    /// Avatar, its gap, and the horizontal padding around the title.
    private static let tabChrome: CGFloat = ClaudeAvatar.tabSize + 5 + 2 * 10
    static let titleFont = NSFont.systemFont(ofSize: 11.5)

    var titles: [String] = [] {
        didSet {
            needsDisplay = true
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }
    /// One per tab, same index space as `titles`; missing entries draw no avatar.
    var states: [PaneActivity] = [] {
        didSet {
            if oldValue.count != states.count {
                moments.removeAll()
                fades.removeAll()
                // Tabs mostly come and go at the end: a tab still in the same
                // state at the same index keeps its clock.
                let old = stateSince
                stateSince = states.indices.map { index in
                    index < old.count && index < oldValue.count && oldValue[index] == states[index] ? old[index] : Date()
                }
                // A new tab says hello with a spin (not the very first fill).
                if !oldValue.isEmpty, states.count > oldValue.count, !reduceMotion {
                    for index in oldValue.count..<states.count { moments[index] = (.celebrate, now) }
                }
            } else {
                for index in states.indices where oldValue[index] != states[index] {
                    stateSince[index] = Date()
                    // A resting avatar has no color to fade to: no fade, no frames.
                    if !reduceMotion, states[index] != .idle {
                        fades[index] = (OpusTheme.activityColor(oldValue[index]) ?? OpusTheme.cream(0.25), now)
                    }
                    // The scene that goes with the change; any change ends the one running.
                    moments[index] = reduceMotion ? nil
                        : ClaudeAvatar.transition(from: oldValue[index], to: states[index]).map { ($0, now) }
                }
            }
            needsDisplay = true
            updateAnimation()
        }
    }
    private var animationTimer: Timer?
    /// The active tab's context share: past `ClaudeAvatar.puffedAt` its cheeks puff out.
    var activeContext: CGFloat? { didSet { if activeContext != oldValue { needsDisplay = true } } }
    /// The week's usage in percent: past `ClaudeAvatar.tiredAt` the avatars droop.
    var weekPercent: Double? { didSet { if weekPercent != oldValue { needsDisplay = true } } }
    /// When each tab entered its current state, same index space as `states`.
    private var stateSince: [Date] = []
    /// The scene each tab is playing (ClaudeAvatar.Moment) and since when, by tab index.
    private var moments: [Int: (kind: ClaudeAvatar.Moment, start: Double)] = [:]
    /// Recent boops, to cycle their kinds and catch five in a row.
    private var boopTimes: [Double] = []
    private var boopCount = 0
    /// The cursor's x while it is over the strip: every avatar looks at it.
    /// Only the avatars look at the pointer: redraw them, not the titles.
    private var hover: NSPoint? {
        didSet {
            guard hover != oldValue else { return }
            for tab in layoutRects().tabs where tab.maxX > 0 && tab.minX < tabRoom {
                setNeedsDisplay(NSRect(x: tab.minX + 6, y: tab.minY, width: ClaudeAvatar.tabSize + 4, height: tab.height))
            }
        }
    }
    /// Where a tab's color is coming from after a state change, and since when.
    private var fades: [Int: (from: NSColor, start: Double)] = [:]
    private static let fadeLength: Double = 0.35
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(displayOptionsChanged), name: .opusAvatarMotionChanged, object: nil)
    }

    /// Reduce motion switched on or off: stop or start the avatars now.
    @objc private func displayOptionsChanged() {
        reduceMotion = !ClaudeAvatar.motionAllowed
        needsDisplay = true
        updateAnimation()
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

    /// What Claude is doing in a tab and for how long, for its tooltip;
    /// nil when idle.
    static func stateLine(_ activity: PaneActivity, for elapsed: TimeInterval) -> String? {
        let minutes = Int(elapsed / 60)
        let span: String
        switch minutes {
        case ..<1: span = "moins d'une minute"
        case ..<60: span = "\(minutes) min"
        default: span = "\(minutes / 60) h \(String(format: "%02d", minutes % 60))"
        }
        switch activity {
        case .idle: return nil
        case .working: return "Claude travaille depuis \(span)"
        case .needsInput: return "Claude t'attend depuis \(span)"
        case .done: return "Claude a fini il y a \(span)"
        }
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

    /// Read once per change of the setting, not on every frame.
    private var reduceMotion = !ClaudeAvatar.motionAllowed
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A tab's pose outside any scene: its state's, except that a wait past
    /// `ClaudeAvatar.dozeAfter` has nodded off.
    private func restingPose(_ index: Int) -> ClaudeAvatar.Pose? {
        if states[index] == .needsInput, stateSince.indices.contains(index),
           Date().timeIntervalSince(stateSince[index]) >= ClaudeAvatar.dozeAfter {
            return ClaudeAvatar.dozing(time: reduceMotion ? 0 : now)
        }
        return ClaudeAvatar.pose(states[index], time: avatarTime(index), reduceMotion: reduceMotion)
    }

    /// The clock a tab's avatar moves on: faster once it has waited long,
    /// without a jump where it speeds up.
    private func avatarTime(_ index: Int) -> Double {
        guard states.indices.contains(index), states[index] == .needsInput, stateSince.indices.contains(index)
        else { return now }
        let insisting = Date().timeIntervalSince(stateSince[index]) - ClaudeAvatar.insistAfter
        return insisting > 0 ? now + insisting * (ClaudeAvatar.insistSpeed - 1) : now
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    /// Keeps a redraw timer only while a tab's avatar moves and the strip
    /// is in a window; a hidden window skips the frames.
    private func updateAnimation() {
        let moving = window != nil
            && (!moments.isEmpty || !fades.isEmpty || states.contains { ClaudeAvatar.isAnimated($0, reduceMotion: reduceMotion) })
        guard moving != (animationTimer != nil) else { return }
        animationTimer?.invalidate()
        animationTimer = nil
        guard moving else { return }
        let timer = Timer(timeInterval: 1 / ClaudeAvatar.framesPerSecond, repeats: true) { [weak self] _ in
            guard let self else { return }
            let over = self.moments.filter { self.now - $0.value.start >= ClaudeAvatar.length($0.value.kind) }
            let faded = self.fades.filter { self.now - $0.value.start >= Self.fadeLength }
            if !over.isEmpty || !faded.isEmpty {
                over.keys.forEach { self.moments.removeValue(forKey: $0) }
                faded.keys.forEach { self.fades.removeValue(forKey: $0) }
                self.needsDisplay = true
                self.updateAnimation()
            }
            guard let window = self.window, window.occlusionState.contains(.visible) else { return }
            // Only the avatars that move: done and resting ones hold still.
            for (index, tab) in self.layoutRects().tabs.enumerated() where tab.maxX > 0 && tab.minX < self.tabRoom {
                let moves = self.moments[index] != nil || self.fades[index] != nil
                    || (self.states.indices.contains(index) && ClaudeAvatar.isAnimated(self.states[index], reduceMotion: self.reduceMotion))
                guard moves else { continue }
                self.setNeedsDisplay(NSRect(x: tab.minX + 6, y: tab.minY, width: ClaudeAvatar.tabSize + 4, height: tab.height))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
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
            var textX = rect.minX + 8
            if index < states.count, states[index] == .idle {
                // Resting: a pale, still, sleeping Claude keeps the titles in line;
                // a boop wakes it up for a spin.
                let size = ClaudeAvatar.tabSize
                let boop = moments[index].flatMap { ClaudeAvatar.moment($0.kind, elapsed: now - $0.start) }
                let spot = NSRect(x: textX, y: rect.midY - size / 2, width: size, height: size)
                // Under the pointer it opens its eyes to look at you.
                let looked = hover.map { spot.insetBy(dx: -2, dy: -2).contains($0) } ?? false
                ClaudeAvatar.draw(boop ?? ClaudeAvatar.Pose(eyes: looked ? .open : .closed, asleep: !looked),
                                  color: OpusTheme.cream(boop != nil || looked ? 0.7 : (isActive ? 0.4 : 0.25)),
                                  in: spot)
            } else if index < states.count, let color = OpusTheme.activityColor(states[index]),
               var pose = moments[index].flatMap({ ClaudeAvatar.moment($0.kind, elapsed: now - $0.start) })
                   ?? restingPose(index) {
                let size = ClaudeAvatar.tabSize
                let spot = NSRect(x: textX, y: rect.midY - size / 2, width: size, height: size)
                if let hover {
                    pose.glance = max(-1, min(1, (hover.x - textX - size / 2) / 60)) * 0.06
                    // Right on it: pleased to be looked at.
                    if spot.insetBy(dx: -2, dy: -2).contains(hover), pose.eyes != .closed { pose.eyes = .happy }
                }
                pose = ClaudeAvatar.tired(pose, weekPercent: weekPercent)
                if !reduceMotion {
                    pose = ClaudeAvatar.lateNight(pose, hour: Calendar.current.component(.hour, from: Date()), time: now)
                }
                if states[index] == .working, stateSince.indices.contains(index) {
                    let worked = Date().timeIntervalSince(stateSince[index])
                    pose.sweat = worked >= ClaudeAvatar.sweatAfter
                    if worked >= ClaudeAvatar.steamAfter { pose.steam = CGFloat(now) }
                }
                if index == activeIndex, let context = activeContext, context >= ClaudeAvatar.puffedAt {
                    pose.puffed = true
                }
                var shade = color
                if let fade = fades[index], now - fade.start < Self.fadeLength {
                    let p = CGFloat((now - fade.start) / Self.fadeLength)
                    shade = fade.from.blended(withFraction: p, of: color) ?? color
                }
                ClaudeAvatar.draw(pose, color: shade, in: spot)
            }
            textX += ClaudeAvatar.tabSize + 5
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [
                .font: Self.titleFont,
                .foregroundColor: isActive ? OpusTheme.cream(0.95) : OpusTheme.cream(0.55),
                .paragraphStyle: para,
            ]
            let title = titles[index].isEmpty ? "Claude" : titles[index]
            let textHeight = ceil(Self.titleFont.ascender - Self.titleFont.descender)
            let textRect = NSRect(x: textX, y: rect.midY - textHeight / 2, width: rect.maxX - 10 - textX, height: textHeight)
            // An animation frame only dirties the avatars: leave the titles be.
            if needsToDraw(textRect) {
                (title as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: attrs)
            }
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
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = hit(point)
        hover = point
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hover = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = hit(point) else { return }
        // Boop: a click on a tab's avatar plays the next boop; five within
        // three seconds and it gets dizzy.
        if index >= 0, let tab = layoutRects().tabs[safe: index],
           point.x >= tab.minX + 6, point.x < tab.minX + 8 + ClaudeAvatar.tabSize + 2, !reduceMotion {
            boopTimes = boopTimes.filter { now - $0 < 3 } + [now]
            let kind: ClaudeAvatar.Moment
            if boopTimes.count >= 5 {
                kind = .dizzy
                boopTimes.removeAll()
            } else {
                kind = ClaudeAvatar.boops[boopCount % ClaudeAvatar.boops.count]
                boopCount += 1
            }
            moments[index] = (kind, now)
            updateAnimation()
        }
        if index == -1 { onNewTab?() } else if index != activeIndex { onSwitch?(index) }
    }
}

extension ChromeTabStrip: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "Nouvel onglet (Cmd+T)" }
        let index = Int(bitPattern: data) - 1
        guard titles.indices.contains(index) else { return "" }
        let base = Self.toolTip(index: index, title: titles[index].isEmpty ? "Claude" : titles[index])
        guard states.indices.contains(index), stateSince.indices.contains(index),
              let line = Self.stateLine(states[index], for: Date().timeIntervalSince(stateSince[index]))
        else { return base }
        return base + "\n" + line
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
