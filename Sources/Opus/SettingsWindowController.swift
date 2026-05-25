// SettingsWindowController — singleton NSWindowController hosting an
// NSTabView with one tab per settings section (General, Appearance, Window).
// Sections are added in their respective phases.

import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabView = NSTabView()

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Opus Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        setupTabView()
    }

    private func setupTabView() {
        guard let content = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10)
        ])

        tabView.addTabViewItem(generalTab())
        // Appearance + Window tabs are added in Phase 4 and Phase 5 respectively.
    }

    /// Stub — filled in Task 6.
    private func generalTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"
        item.view = NSView()
        return item
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
