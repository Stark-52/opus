// MenuBarAvatar: Claude in the menu bar. It shows the strongest state across
// every tab of every window (ClaudeAvatar.strongest), so a glance from any
// app says whether Claude is working, waiting for you, or done. Resting, it
// is a template image that follows the menu bar's own color. A click shows
// Opus; Cmd-drag it out of the menu bar to remove it.

import AppKit

final class MenuBarAvatar {
    static let shared = MenuBarAvatar()
    /// The image's side; the avatar takes 0.78 of it so a hop is never cut.
    private static let size: CGFloat = 22

    private struct Report {
        weak var source: AnyObject?
        var states: [PaneActivity]
        var focus: (Int) -> Void
    }

    private var item: NSStatusItem?
    private var reports: [Report] = []
    private(set) var activity: PaneActivity = .idle
    /// The week's usage in percent, for heavy lids and the tooltip.
    private var weekPercent: Double?
    /// How many tabs wait for an answer; from two up, the count shows.
    private var waiting = 0
    /// Turns finished today (counted when the strongest state goes from
    /// working to done); every tenth celebration gets heart eyes.
    private var finished: (day: Int, count: Int) = (0, 0)
    private var heartsThisTime = false
    private var appearanceWatch: NSKeyValueObservation?

    static func hearts(afterFinishing count: Int) -> Bool {
        count > 0 && count % 10 == 0
    }
    private var celebrationStart: Double?
    private var timer: Timer?
    private let clickTarget = ClickTarget()
    /// Brings Opus forward without hiding it, before a tab is focused.
    private var reveal: () -> Void = {}

    /// Whether the avatar sits in the menu bar; Cmd-drag can clear it too.
    var isShown: Bool {
        get { item?.isVisible ?? false }
        set {
            item?.isVisible = newValue
            render()
            updateTimer()
        }
    }

    /// The image the menu bar shows right now, for the preview's snapshots.
    var currentImage: NSImage? { item?.button?.image }
    /// The whole button, count included, for the preview's snapshots.
    var currentButton: NSView? { item?.button }

    /// Read once per change of the setting, not on every frame.
    private var reduceMotion = !ClaudeAvatar.motionAllowed
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A click shows the tab that waits for you, else the one that just
    /// finished; with neither it calls `onClick` (show or hide Opus).
    /// `autosave` off keeps the item's position and visibility out of the
    /// defaults Opus shares, for a preview beside a running Opus.
    func install(onClick: @escaping () -> Void, reveal: @escaping () -> Void, autosave: Bool = true) {
        guard item == nil else { return }
        self.reveal = reveal
        // Variable: the count of waiting sessions sits beside the avatar.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        if autosave { item.autosaveName = "OpusClaudeAvatar" }
        item.behavior = .removalAllowed
        clickTarget.action = { [weak self] in
            self?.refresh()
            // Boop: a click makes it spin, whatever it does next.
            if let self, !self.reduceMotion {
                self.celebrationStart = self.now
                self.heartsThisTime = false
                self.render()
                self.updateTimer()
            }
            guard let self, let (report, index) = self.tabToShow() else { return onClick() }
            self.reveal()
            report.focus(index)
        }
        item.button?.target = clickTarget
        item.button?.action = #selector(ClickTarget.fire)
        self.item = item
        // A light or dark menu bar changes the soft edge: redraw on the switch.
        appearanceWatch = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.render() }
        }
        // Hello: one spin at launch.
        if !reduceMotion { celebrationStart = now }
        render()
        updateTimer()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.motionChanged() }
        NotificationCenter.default.addObserver(forName: .opusAvatarMotionChanged, object: nil, queue: .main) { [weak self] _ in
            self?.motionChanged()
        }
    }

    private func motionChanged() {
        reduceMotion = !ClaudeAvatar.motionAllowed
        if reduceMotion { celebrationStart = nil }
        render()
        updateTimer()
    }

    private func tabToShow() -> (Report, Int)? {
        for wanted in [PaneActivity.needsInput, .done] {
            for report in reports where report.source != nil {
                if let index = report.states.firstIndex(of: wanted) { return (report, index) }
            }
        }
        return nil
    }

    /// `source`'s tabs, one state each, and how to bring one of them up;
    /// a source that goes away stops counting.
    func report(_ states: [PaneActivity], from source: AnyObject, focus: @escaping (Int) -> Void) {
        reports.removeAll { $0.source === source }
        reports.append(Report(source: source, states: states, focus: focus))
        refresh()
    }

    /// The latest usage windows; only the week's matters here.
    func reportUsage(_ windows: [UsageWindow]) {
        let week = windows.first { $0.kind == .sevenDay }?.percent
        guard week != weekPercent else { return }
        // A fresh week deserves a party.
        if ClaudeAvatar.weekReset(from: weekPercent, to: week), !reduceMotion {
            celebrationStart = now
            heartsThisTime = false
        }
        weekPercent = week
        render()
        updateTimer()
    }

    /// Drops the reports of sources that went away, so a closed window does
    /// not leave the avatar working forever, and recomputes the state.
    private func refresh() {
        reports.removeAll { $0.source == nil }
        let all = reports.flatMap(\.states)
        let next = ClaudeAvatar.strongest(all)
        let waitingNow = all.filter { $0 == .needsInput }.count
        if waitingNow != waiting {
            waiting = waitingNow
            render()
        }
        guard next != activity else { return }
        if activity == .working, next == .done {
            let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
            finished = finished.day == day ? (day, finished.count + 1) : (day, 1)
            heartsThisTime = Self.hearts(afterFinishing: finished.count)
            if !reduceMotion { celebrationStart = now }
        }
        if next != .done { celebrationStart = nil }
        activity = next
        render()
        updateTimer()
        DockAvatar.shared.follow()
    }

    private func updateTimer() {
        let moving = item?.isVisible == true && (celebrationStart != nil || ClaudeAvatar.isAnimated(activity, reduceMotion: reduceMotion))
        guard moving != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard moving else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            // Cmd-drag can hide the item behind our back: stop drawing for nobody.
            guard self.item?.isVisible == true else { return self.updateTimer() }
            self.render()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func render() {
        guard let button = item?.button else { return }
        if let start = celebrationStart, ClaudeAvatar.celebrating(elapsed: now - start) == nil {
            celebrationStart = nil
            heartsThisTime = false
            updateTimer()
        }
        let celebration = celebrationStart.flatMap { ClaudeAvatar.celebrating(elapsed: now - $0) }
        if let color = OpusTheme.activityColor(activity),
           let pose = celebration ?? ClaudeAvatar.pose(activity, time: now, reduceMotion: reduceMotion) {
            var shown = ClaudeAvatar.tired(pose, weekPercent: weekPercent)
            if celebration != nil, heartsThisTime { shown.eyes = .hearts }
            if !reduceMotion {
                shown = ClaudeAvatar.lateNight(shown, hour: Calendar.current.component(.hour, from: Date()), time: now)
            }
            let lightBar = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
            button.image = ClaudeAvatar.image(shown, color: color, size: Self.size, shadow: lightBar)
        } else {
            let pose = ClaudeAvatar.tired(celebration ?? ClaudeAvatar.Pose(), weekPercent: weekPercent)
            let image = ClaudeAvatar.image(pose, color: .black, size: Self.size, knockout: true)
            image.isTemplate = true
            button.image = image
        }
        // Only the image changes from frame to frame: title and tooltip are
        // set when they change, so the status item is not laid out again.
        let badge = Self.badge(waiting)
        if button.title != badge { button.title = badge }
        let today = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let tip = Self.toolTip(activity, weekPercent: weekPercent, waiting: waiting,
                               finished: finished.day == today ? finished.count : 0)
        if button.toolTip != tip {
            button.toolTip = tip
            button.setAccessibilityLabel(tip)
        }
    }

    /// The count beside the avatar: empty for none or one.
    static func badge(_ waiting: Int) -> String {
        waiting >= 2 ? "\(waiting)" : ""
    }

    static func toolTip(_ activity: PaneActivity, weekPercent: Double? = nil, waiting: Int = 0, finished: Int = 0) -> String {
        let base = stateToolTip(activity, weekPercent: weekPercent, waiting: waiting)
        guard finished > 0 else { return base }
        return base + "\n" + (finished == 1 ? "1 tâche finie aujourd'hui" : "\(finished) tâches finies aujourd'hui")
    }

    private static func stateToolTip(_ activity: PaneActivity, weekPercent: Double?, waiting: Int) -> String {
        let state: String
        switch activity {
        case .idle: state = "Claude se repose"
        case .working: state = "Claude travaille"
        case .needsInput: state = waiting >= 2 ? "\(waiting) sessions t'attendent" : "Claude attend ta réponse"
        case .done: state = "Claude a fini"
        }
        guard let weekPercent else { return state }
        let week = "semaine \(Int(weekPercent.rounded()))\u{00A0}%"
        return state + "\n" + (weekPercent >= 100 ? week + ", limite atteinte" : week)
    }
}

private final class ClickTarget: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}
