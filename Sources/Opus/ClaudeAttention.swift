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
            NSApp.dockTile.badgeLabel = "●"
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
        NSApp.dockTile.badgeLabel = nil
    }

    private func postNotification(title: String) {
        let center = UNUserNotificationCenter.current()
        let fire = {
            let content = UNMutableNotificationContent()
            content.title = "Claude needs you"
            content.body = title.isEmpty ? "The session is waiting." : title
            let req = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(req, withCompletionHandler: nil)
        }
        if authRequested { fire(); return }
        authRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async(execute: fire) }
        }
    }
}
