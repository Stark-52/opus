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

    private func postNotification(title: String) {
        // UNUserNotificationCenter requires a real bundle; badge + Dock
        // bounce (postSystemSignals' other side effects) stay alive without one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = "Claude needs you"
            content.body = title.isEmpty ? "The session is waiting." : title
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

/// The Dock tile while Claude waits for the user: the app icon with the
/// avatar hopping in its corner, where a "●" badge used to sit.
final class DockAvatar {
    static let shared = DockAvatar()
    private var shown = false
    private var timer: Timer?

    func show() {
        guard !shown else { return }
        shown = true
        let tile = NSApp.dockTile
        tile.contentView = DockAvatarView(frame: NSRect(origin: .zero, size: tile.size))
        tile.display()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { _ in NSApp.dockTile.display() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        guard shown else { return }
        shown = false
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockAvatarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        guard let pose = ClaudeAvatar.pose(.needsInput, time: ProcessInfo.processInfo.systemUptime,
                                           reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        else { return }
        let side = bounds.width * 0.46
        let spot = NSRect(x: bounds.maxX - side, y: bounds.minY + bounds.height * 0.02, width: side, height: side)
        OpusTheme.panelBackground.setFill()
        NSBezierPath(ovalIn: spot.insetBy(dx: side * 0.04, dy: side * 0.04)).fill()
        ClaudeAvatar.draw(pose, color: OpusTheme.red, in: spot.insetBy(dx: side * 0.1, dy: side * 0.1))
    }
}
