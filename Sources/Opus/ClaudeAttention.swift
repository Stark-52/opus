// ClaudeAttention — turns terminal BELs into native attention signals when
// the user is looking elsewhere. Claude Code's default notification channel
// is the terminal bell, so this is "Claude finished / needs input" for free.

import AppKit
import UserNotifications

final class ClaudeAttention {
    static let shared = ClaudeAttention()
    private var authRequested = false

    /// Timestamp of the last signal actually fired. Exposed read-only so
    /// tests can assert debounce behavior without touching AppKit/UN state.
    private(set) var lastSignalAt: Date?

    /// Whether Opus is currently visible/focused to the user. Wired by
    /// AppDelegate at launch to also account for the non-activating panel
    /// (NSApp.isActive alone misses it — see applicationDidFinishLaunching).
    /// Default keeps the old NSApp.isActive-only behavior for safety (and
    /// for anything that constructs ClaudeAttention before AppDelegate wires
    /// the real check, e.g. tests).
    var isUserLookingAtOpus: () -> Bool = { NSApp.isActive }

    /// The actual badge/bounce/notification side effects, factored out so
    /// tests can swap in a no-op: UNUserNotificationCenter.current() can
    /// crash/error in a bundle-less SPM test process, so nothing in the test
    /// target may reach the real implementation.
    var postSystemSignals: (String) -> Void = { _ in }

    /// Bell storms (several rings in quick succession) collapse to a single
    /// signal instead of stacking one notification banner per bell.
    private static let debounceInterval: TimeInterval = 3

    private init() {
        postSystemSignals = { [weak self] title in
            DockAvatar.shared.show()
            NSApp.requestUserAttention(.informationalRequest)   // Dock bounce, once
            self?.postNotification(title: title)
        }
    }

    func bellReceived(title: String) {
        guard OpusPreferences.shared.notifyOnBell else { return }
        // Only signal when the user is NOT already looking at Opus.
        guard !isUserLookingAtOpus() else { return }
        if let last = lastSignalAt, Date().timeIntervalSince(last) < Self.debounceInterval { return }
        lastSignalAt = Date()
        postSystemSignals(title)
    }

    func clear() {
        DockAvatar.shared.hide()
    }

    /// Constant so a fresh signal REPLACES any still-showing banner instead
    /// of stacking one notification per bell over a long session.
    private static let notificationIdentifier = "opus.claude.attention"

    /// The waiting avatar, "?" bubble and all, as the banner's thumbnail.
    /// Written to a fresh file each time: the notification center moves it.
    private static func avatarAttachment() -> UNNotificationAttachment? {
        guard let pose = ClaudeAvatar.pose(.needsInput, time: 0.3),
              let png = ClaudeAvatar.pngData(pose, color: OpusTheme.red, size: 256) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opus-avatar-\(UUID().uuidString).png")
        guard (try? png.write(to: url)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "claude-avatar", url: url, options: nil)
    }

    private func postNotification(title: String) {
        // UNUserNotificationCenter requires a real bundle; badge + Dock
        // bounce (postSystemSignals' other side effects) stay alive without one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = "Claude needs you"
            content.body = title.isEmpty ? "The session is waiting." : title
            if let attachment = Self.avatarAttachment() { content.attachments = [attachment] }
            let req = UNNotificationRequest(
                identifier: Self.notificationIdentifier, content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
        if authRequested { fire(); return }
        authRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async(execute: fire) }
        }
    }
}

/// The Dock tile while a bell is pending: the app icon with the avatar in
/// its corner, where a "●" badge used to sit. The bell rings both when
/// Claude needs an answer and when it has finished, so the avatar takes the
/// state the tabs report (MenuBarAvatar): red and hopping, or green and
/// smiling; red when the tabs say neither.
final class DockAvatar {
    static let shared = DockAvatar()
    /// What the tile shows; nil when it is the plain icon.
    private var shown: PaneActivity?
    private var timer: Timer?

    /// `activity` is .done or .needsInput; by default, done when the tabs
    /// say so and needs-input otherwise.
    func show(_ wanted: PaneActivity? = nil) {
        let activity: PaneActivity = wanted ?? (MenuBarAvatar.shared.activity == .done ? .done : .needsInput)
        guard shown != activity else { return }
        timer?.invalidate()
        timer = nil
        shown = activity
        let tile = NSApp.dockTile
        tile.contentView = DockAvatarView(frame: NSRect(origin: .zero, size: tile.size), activity: activity)
        tile.display()
        guard ClaudeAvatar.motionAllowed else { return }
        // Every Dock frame crosses to the Dock process: a minute of slow
        // hopping when Claude waits, one quick burst of confetti when it has
        // finished, then the tile rests on its last frame.
        let start = ProcessInfo.processInfo.systemUptime
        let finished = activity == .done
        let length = finished ? ClaudeAvatar.celebrationLength + 0.2 : 60
        let timer = Timer(timeInterval: finished ? 1.0 / 15 : 1.0 / 6, repeats: true) { [weak self] timer in
            NSApp.dockTile.display()
            guard ProcessInfo.processInfo.systemUptime - start > length else { return }
            timer.invalidate()
            self?.timer = nil
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The tabs changed state: a tile already up follows them, since the
    /// bell can ring before the hook that says Claude has finished.
    /// Only between the two states a bell means: a tab starting work or a
    /// closed tab leaves the tile as it is.
    func follow() {
        guard shown != nil else { return }
        switch MenuBarAvatar.shared.activity {
        case .done: show(.done)
        case .needsInput: show(.needsInput)
        case .working, .idle: break
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        guard shown != nil else { return }
        shown = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockAvatarView: NSView {
    private let activity: PaneActivity
    /// When the tile went up: a done tile celebrates from there.
    private let shownAt = ProcessInfo.processInfo.systemUptime

    init(frame: NSRect, activity: PaneActivity) {
        self.activity = activity
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let still = !ClaudeAvatar.motionAllowed
        let now = ProcessInfo.processInfo.systemUptime
        let party = activity == .done && !still ? ClaudeAvatar.celebrating(elapsed: now - shownAt) : nil
        guard let color = OpusTheme.activityColor(activity),
              let pose = party ?? ClaudeAvatar.pose(activity, time: now, reduceMotion: still)
        else { return }
        let side = bounds.width * 0.46
        let spot = NSRect(x: bounds.maxX - side, y: bounds.minY + bounds.height * 0.02, width: side, height: side)
        OpusTheme.panelBackground.setFill()
        NSBezierPath(ovalIn: spot.insetBy(dx: side * 0.04, dy: side * 0.04)).fill()
        ClaudeAvatar.draw(pose, color: color, in: ClaudeAvatar.fittedRect(in: spot.insetBy(dx: side * 0.04, dy: side * 0.04)))
    }
}
