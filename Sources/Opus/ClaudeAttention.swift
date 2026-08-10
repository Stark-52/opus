// ClaudeAttention — turns terminal BELs into native attention signals when
// the user is looking elsewhere. Claude Code's default notification channel
// is the terminal bell, so this is "Claude finished / needs input" for free.

import AppKit
import UserNotifications

final class ClaudeAttention {
    static let shared = ClaudeAttention()
    private var authRequested = false

    func bellReceived(title: String) {
        guard OpusPreferences.shared.notifyOnBell else { return }
        // Only signal when the user is NOT already looking at Opus.
        guard !NSApp.isActive else { return }
        NSApp.dockTile.badgeLabel = "●"
        NSApp.requestUserAttention(.informationalRequest)   // Dock bounce, once
        postNotification(title: title)
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
