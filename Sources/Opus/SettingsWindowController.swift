// SettingsWindowController — singleton NSWindowController hosting an
// NSTabView with one tab per settings section (General, Appearance, Window).
// Sections are added in their respective phases.

import AppKit
import UniformTypeIdentifiers

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private let tabView = NSTabView()
    private var customCommandField: NSTextField?
    private var cwdField: NSTextField?
    private var tintWell: NSColorWell?
    private var tintLabel: NSTextField?
    private var imagePathField: NSTextField?
    private var imageLabel: NSTextField?
    private var imagePickButton: NSButton?

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
        tabView.addTabViewItem(appearanceTab())
        tabView.addTabViewItem(windowModeTab())
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

    private func appearanceTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "appearance")
        item.label = "Appearance"

        let view = NSView()

        let modeLabel = NSTextField(labelWithString: "Background")
        modeLabel.alignment = .right
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: ["Default (blur + dark tint)", "Transparent", "Custom tint", "Background image"])
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        let currentMode = OpusPreferences.shared.appearanceMode
        let modeIndex: Int = {
            switch currentMode {
            case "transparent": return 1
            case "tint":        return 2
            case "image":       return 3
            default:            return 0
            }
        }()
        modePopup.selectItem(at: modeIndex)
        modePopup.target = self
        modePopup.action = #selector(onAppearanceModeChanged(_:))

        // Tint color picker (visible for "tint" mode)
        let tintLabel = NSTextField(labelWithString: "Tint color")
        tintLabel.alignment = .right
        let tintWell = NSColorWell()
        let rgba = OpusPreferences.shared.appearanceTintRGBA
        tintWell.color = NSColor(
            red: CGFloat(rgba[0]), green: CGFloat(rgba[1]),
            blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3])
        )
        tintWell.target = self
        tintWell.action = #selector(onTintColorChanged(_:))
        tintWell.translatesAutoresizingMaskIntoConstraints = false
        self.tintWell = tintWell
        self.tintLabel = tintLabel

        // Image picker (visible for "image" mode)
        let imgLabel = NSTextField(labelWithString: "Background image")
        imgLabel.alignment = .right
        let imgPath = NSTextField(string: OpusPreferences.shared.appearanceImagePath ?? "")
        imgPath.placeholderString = "/path/to/image.png"
        imgPath.isEditable = false
        let imgPickBtn = NSButton(title: "Choose…", target: self, action: #selector(pickAppearanceImage))
        imgPickBtn.bezelStyle = .rounded
        imgPath.translatesAutoresizingMaskIntoConstraints = false
        imgPickBtn.translatesAutoresizingMaskIntoConstraints = false
        self.imagePathField = imgPath
        self.imageLabel = imgLabel
        self.imagePickButton = imgPickBtn

        for v in [modeLabel, modePopup, tintLabel, tintWell, imgLabel, imgPath, imgPickBtn] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            modeLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            modeLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            modeLabel.widthAnchor.constraint(equalToConstant: 160),
            modePopup.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
            modePopup.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 10),
            modePopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            tintLabel.topAnchor.constraint(equalTo: modePopup.bottomAnchor, constant: 20),
            tintLabel.leadingAnchor.constraint(equalTo: modeLabel.leadingAnchor),
            tintLabel.widthAnchor.constraint(equalToConstant: 160),
            tintWell.centerYAnchor.constraint(equalTo: tintLabel.centerYAnchor),
            tintWell.leadingAnchor.constraint(equalTo: modePopup.leadingAnchor),
            tintWell.widthAnchor.constraint(equalToConstant: 80),
            tintWell.heightAnchor.constraint(equalToConstant: 24),

            imgLabel.topAnchor.constraint(equalTo: tintLabel.bottomAnchor, constant: 24),
            imgLabel.leadingAnchor.constraint(equalTo: modeLabel.leadingAnchor),
            imgLabel.widthAnchor.constraint(equalToConstant: 160),
            imgPath.centerYAnchor.constraint(equalTo: imgLabel.centerYAnchor),
            imgPath.leadingAnchor.constraint(equalTo: modePopup.leadingAnchor),
            imgPath.trailingAnchor.constraint(equalTo: imgPickBtn.leadingAnchor, constant: -8),
            imgPickBtn.centerYAnchor.constraint(equalTo: imgLabel.centerYAnchor),
            imgPickBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        refreshAppearanceVisibility(mode: currentMode)
        item.view = view
        return item
    }

    private func windowModeTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "window")
        item.label = "Window"
        let view = NSView()

        let label = NSTextField(labelWithString: "Window mode")
        label.alignment = .right
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: [
            "Slide-down panel only",
            "Main window only",
            "Both (Cmd+Ctrl+T panel, Cmd+Ctrl+M main)"
        ])
        let current = OpusPreferences.shared.windowMode
        popup.selectItem(at: ["panel", "main", "both"].firstIndex(of: current) ?? 0)
        popup.target = self
        popup.action = #selector(onWindowModeChanged(_:))

        let hint = NSTextField(wrappingLabelWithString:
            "Restart Opus to apply window mode changes. " +
            "Main window has its own private session (does not mirror Terminal.app).")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor

        for v in [label, popup, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.widthAnchor.constraint(equalToConstant: 160),
            popup.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            popup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            hint.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: popup.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])

        item.view = view
        return item
    }

    @objc private func onWindowModeChanged(_ sender: NSPopUpButton) {
        let modes = ["panel", "main", "both"]
        OpusPreferences.shared.windowMode = modes[sender.indexOfSelectedItem]
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

    @objc private func onAppearanceModeChanged(_ sender: NSPopUpButton) {
        let mode: String
        switch sender.indexOfSelectedItem {
        case 1: mode = "transparent"
        case 2: mode = "tint"
        case 3: mode = "image"
        default: mode = "default"
        }
        OpusPreferences.shared.appearanceMode = mode
        refreshAppearanceVisibility(mode: mode)
    }

    @objc private func onTintColorChanged(_ sender: NSColorWell) {
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        OpusPreferences.shared.appearanceTintRGBA = [
            Double(c.redComponent), Double(c.greenComponent),
            Double(c.blueComponent), Double(c.alphaComponent)
        ]
    }

    @objc private func pickAppearanceImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            OpusPreferences.shared.appearanceImagePath = url.path
            imagePathField?.stringValue = url.path
        }
    }

    private func refreshAppearanceVisibility(mode: String) {
        let showTint = (mode == "tint")
        let showImage = (mode == "image")
        tintLabel?.isHidden = !showTint
        tintWell?.isHidden = !showTint
        imageLabel?.isHidden = !showImage
        imagePathField?.isHidden = !showImage
        imagePickButton?.isHidden = !showImage
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
