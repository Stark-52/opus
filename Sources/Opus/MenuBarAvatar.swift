// MenuBarAvatar: Claude in the menu bar. It shows the strongest state across
// every tab of every window (ClaudeAvatar.strongest), so a glance from any
// app says whether Claude is working, waiting for you, or done. Resting, it
// is a template image that follows the menu bar's own color. A click shows
// Opus; Cmd-drag it out of the menu bar to remove it.

import AppKit

final class MenuBarAvatar {
    static let shared = MenuBarAvatar()
    private static let size: CGFloat = 18

    private struct Report {
        weak var source: AnyObject?
        var states: [PaneActivity]
        var focus: (Int) -> Void
    }

    private var item: NSStatusItem?
    private var reports: [Report] = []
    private(set) var activity: PaneActivity = .idle
    private var celebrationStart: Double?
    private var timer: Timer?
    private let clickTarget = ClickTarget()
    /// Brings Opus forward without hiding it, before a tab is focused.
    private var reveal: () -> Void = {}

    /// Whether the avatar sits in the menu bar; Cmd-drag can clear it too.
    var isShown: Bool {
        get { item?.isVisible ?? false }
        set { item?.isVisible = newValue }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// A click shows the tab that waits for you, else the one that just
    /// finished; with neither it calls `onClick` (show or hide Opus).
    func install(onClick: @escaping () -> Void, reveal: @escaping () -> Void) {
        guard item == nil else { return }
        self.reveal = reveal
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "OpusClaudeAvatar"
        item.behavior = .removalAllowed
        clickTarget.action = { [weak self] in
            guard let self, let (report, index) = self.tabToShow() else { return onClick() }
            self.reveal()
            report.focus(index)
        }
        item.button?.target = clickTarget
        item.button?.action = #selector(ClickTarget.fire)
        self.item = item
        render()
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
        reports.removeAll { $0.source == nil || $0.source === source }
        reports.append(Report(source: source, states: states, focus: focus))
        let next = ClaudeAvatar.strongest(reports.flatMap(\.states))
        guard next != activity else { return }
        if activity == .working, next == .done, !reduceMotion { celebrationStart = now }
        activity = next
        render()
        updateTimer()
    }

    private func updateTimer() {
        let moving = item != nil && (celebrationStart != nil || ClaudeAvatar.isAnimated(activity, reduceMotion: reduceMotion))
        guard moving != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard moving else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.render() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func render() {
        guard let button = item?.button else { return }
        if let start = celebrationStart, ClaudeAvatar.celebrating(elapsed: now - start) == nil {
            celebrationStart = nil
            updateTimer()
        }
        let celebration = celebrationStart.flatMap { ClaudeAvatar.celebrating(elapsed: now - $0) }
        if let color = OpusTheme.activityColor(activity),
           let pose = celebration ?? ClaudeAvatar.pose(activity, time: now, reduceMotion: reduceMotion) {
            button.image = ClaudeAvatar.image(pose, color: color, size: Self.size)
        } else {
            let image = ClaudeAvatar.image(ClaudeAvatar.Pose(), color: .black, size: Self.size, knockout: true)
            image.isTemplate = true
            button.image = image
        }
        button.toolTip = Self.toolTip(activity)
    }

    static func toolTip(_ activity: PaneActivity) -> String {
        switch activity {
        case .idle: return "Claude se repose"
        case .working: return "Claude travaille"
        case .needsInput: return "Claude attend ta réponse"
        case .done: return "Claude a fini"
        }
    }
}

private final class ClickTarget: NSObject {
    var action: (() -> Void)?
    @objc func fire() { action?() }
}
