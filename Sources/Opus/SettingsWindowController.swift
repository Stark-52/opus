// SettingsWindowController — singleton NSWindowController hosting an
// NSTabView with one tab per settings section (General, Appearance, Window).
// Sections are added in their respective phases.

import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabView = NSTabView()
    private var customCommandField: NSTextField?
    private var cwdField: NSTextField?

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

    private func generalTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "general")
        item.label = "General"

        let view = NSView()

        // — Initial command —
        let cmdLabel = makeFieldLabel("Initial command")
        let cmdPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        cmdPopup.translatesAutoresizingMaskIntoConstraints = false
        for preset in OpusInitialCommandPreset.allCases {
            cmdPopup.addItem(withTitle: preset.displayName)
        }
        let current = OpusPreferences.shared.initialCommandPreset
        cmdPopup.selectItem(at: OpusInitialCommandPreset.allCases.firstIndex(of: current) ?? 0)
        cmdPopup.target = self
        cmdPopup.action = #selector(onPresetChanged(_:))

        // — Custom command field (visible only when preset == .custom) —
        let customField = NSTextField(string: OpusPreferences.shared.customCommand)
        customField.translatesAutoresizingMaskIntoConstraints = false
        customField.placeholderString = "e.g. tmux attach -t main"
        customField.target = self
        customField.action = #selector(onCustomCommandSubmitted(_:))
        customField.isHidden = (current != .custom)
        self.customCommandField = customField

        // — Working directory —
        let cwdLabel = makeFieldLabel("Working directory")
        let cwdField = NSTextField(string: OpusPreferences.shared.workingDirectory)
        cwdField.translatesAutoresizingMaskIntoConstraints = false
        cwdField.target = self
        cwdField.action = #selector(onCwdSubmitted(_:))

        let cwdPickBtn = NSButton(title: "Browse…", target: self, action: #selector(pickCwd))
        cwdPickBtn.translatesAutoresizingMaskIntoConstraints = false
        cwdPickBtn.bezelStyle = .rounded
        self.cwdField = cwdField

        // — Pairing mode —
        let pairLabel = makeFieldLabel("Terminal.app pairing")
        let pairPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        pairPopup.translatesAutoresizingMaskIntoConstraints = false
        for mode in OpusPairingMode.allCases {
            pairPopup.addItem(withTitle: mode.displayName)
        }
        pairPopup.selectItem(at: OpusPairingMode.allCases.firstIndex(of: OpusPreferences.shared.pairingMode) ?? 0)
        pairPopup.target = self
        pairPopup.action = #selector(onPairingChanged(_:))

        let pairHint = NSTextField(labelWithString: "Restart Opus to apply pairing changes.")
        pairHint.translatesAutoresizingMaskIntoConstraints = false
        pairHint.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        pairHint.textColor = .secondaryLabelColor

        for v in [cmdLabel, cmdPopup, customField, cwdLabel, cwdField, cwdPickBtn, pairLabel, pairPopup, pairHint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        NSLayoutConstraint.activate([
            cmdLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            cmdLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            cmdLabel.widthAnchor.constraint(equalToConstant: 180),
            cmdPopup.centerYAnchor.constraint(equalTo: cmdLabel.centerYAnchor),
            cmdPopup.leadingAnchor.constraint(equalTo: cmdLabel.trailingAnchor, constant: 10),
            cmdPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            customField.topAnchor.constraint(equalTo: cmdPopup.bottomAnchor, constant: 6),
            customField.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            customField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            cwdLabel.topAnchor.constraint(equalTo: customField.bottomAnchor, constant: 24),
            cwdLabel.leadingAnchor.constraint(equalTo: cmdLabel.leadingAnchor),
            cwdLabel.widthAnchor.constraint(equalToConstant: 180),
            cwdField.centerYAnchor.constraint(equalTo: cwdLabel.centerYAnchor),
            cwdField.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            cwdField.trailingAnchor.constraint(equalTo: cwdPickBtn.leadingAnchor, constant: -8),
            cwdPickBtn.centerYAnchor.constraint(equalTo: cwdLabel.centerYAnchor),
            cwdPickBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            pairLabel.topAnchor.constraint(equalTo: cwdLabel.bottomAnchor, constant: 30),
            pairLabel.leadingAnchor.constraint(equalTo: cmdLabel.leadingAnchor),
            pairLabel.widthAnchor.constraint(equalToConstant: 180),
            pairPopup.centerYAnchor.constraint(equalTo: pairLabel.centerYAnchor),
            pairPopup.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            pairPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pairHint.topAnchor.constraint(equalTo: pairPopup.bottomAnchor, constant: 4),
            pairHint.leadingAnchor.constraint(equalTo: pairPopup.leadingAnchor),
            pairHint.trailingAnchor.constraint(equalTo: pairPopup.trailingAnchor)
        ])

        item.view = view
        return item
    }

    private func makeFieldLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        l.font = NSFont.systemFont(ofSize: 13)
        return l
    }

    @objc private func onPresetChanged(_ sender: NSPopUpButton) {
        let preset = OpusInitialCommandPreset.allCases[sender.indexOfSelectedItem]
        OpusPreferences.shared.initialCommandPreset = preset
        customCommandField?.isHidden = (preset != .custom)
    }

    @objc private func onCustomCommandSubmitted(_ sender: NSTextField) {
        OpusPreferences.shared.customCommand = sender.stringValue
    }

    @objc private func onCwdSubmitted(_ sender: NSTextField) {
        OpusPreferences.shared.workingDirectory = sender.stringValue
    }

    @objc private func pickCwd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: OpusPreferences.shared.workingDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            OpusPreferences.shared.workingDirectory = url.path
            cwdField?.stringValue = url.path
        }
    }

    @objc private func onPairingChanged(_ sender: NSPopUpButton) {
        let mode = OpusPairingMode.allCases[sender.indexOfSelectedItem]
        OpusPreferences.shared.pairingMode = mode
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
