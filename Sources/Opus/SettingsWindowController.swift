// SettingsWindowController — singleton NSWindowController hosting an
// NSTabView with one tab per settings section (General, Appearance, Window).
// Sections are added in their respective phases.

import AppKit
import ServiceManagement
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
    private var skipPermsCheckbox: NSButton?
    private var skipPermsHint: NSTextField?
    private var resumeCheckbox: NSButton?
    private var loginErrorLabel: NSTextField?
    private var loginItemCheckbox: NSButton?
    private var confirmRestartCheckbox: NSButton?
    private var fontSizeField: NSTextField?
    private var fontSizeStepper: NSStepper?
    private var fontFamilies: [String] = []

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
        tabView.addTabViewItem(displayTab())
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
        customField.placeholderString = "e.g. tmux attach -t main"
        customField.target = self
        customField.action = #selector(onCustomCommandSubmitted(_:))
        customField.isHidden = (current != .custom)
        self.customCommandField = customField

        // — Claude launch flags (visible only when preset == .claude) —
        let isClaude = (current == .claude)
        let skipCheckbox = NSButton(
            checkboxWithTitle: "Skip permission prompts (--dangerously-skip-permissions)",
            target: self, action: #selector(onSkipPermissionsToggled(_:))
        )
        skipCheckbox.state = OpusPreferences.shared.skipPermissions ? .on : .off
        skipCheckbox.isHidden = !isClaude
        self.skipPermsCheckbox = skipCheckbox

        let skipHint = NSTextField(wrappingLabelWithString:
            "Default for new Opus launches — Claude runs tools without asking for confirmation. " +
            "You can also flip it live per-conversation with the shield button.")
        skipHint.font = NSFont.systemFont(ofSize: 11)
        skipHint.textColor = .secondaryLabelColor
        skipHint.isHidden = !isClaude
        self.skipPermsHint = skipHint

        let resumeCheckbox = NSButton(
            checkboxWithTitle: "Resume last conversation on launch (--continue)",
            target: self, action: #selector(onResumeToggled(_:))
        )
        resumeCheckbox.state = OpusPreferences.shared.resumeLastConversation ? .on : .off
        resumeCheckbox.isHidden = !isClaude
        self.resumeCheckbox = resumeCheckbox

        // — Working directory —
        let cwdLabel = makeFieldLabel("Working directory")
        let cwdField = NSTextField(string: OpusPreferences.shared.workingDirectory)
        cwdField.target = self
        cwdField.action = #selector(onCwdSubmitted(_:))

        let cwdPickBtn = NSButton(title: "Browse…", target: self, action: #selector(pickCwd))
        cwdPickBtn.bezelStyle = .rounded
        self.cwdField = cwdField

        // — Restart confirmation —
        let confirmCheckbox = NSButton(
            checkboxWithTitle: "Ask before restarting the session (Cmd+Ctrl+R)",
            target: self, action: #selector(onConfirmRestartToggled(_:))
        )
        confirmCheckbox.state = OpusPreferences.shared.confirmRestart ? .on : .off
        self.confirmRestartCheckbox = confirmCheckbox

        // — Launch at login —
        let loginCheckbox = NSButton(
            checkboxWithTitle: "Launch Opus at login",
            target: self, action: #selector(onLaunchAtLoginToggled(_:))
        )
        loginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        self.loginItemCheckbox = loginCheckbox

        let loginError = NSTextField(wrappingLabelWithString: "")
        loginError.font = NSFont.systemFont(ofSize: 11)
        loginError.textColor = .systemRed
        loginError.isHidden = true
        self.loginErrorLabel = loginError

        for v in [cmdLabel, cmdPopup, customField, skipCheckbox, skipHint, resumeCheckbox,
                  cwdLabel, cwdField, cwdPickBtn, confirmCheckbox, loginCheckbox, loginError] {
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

            skipCheckbox.topAnchor.constraint(equalTo: customField.bottomAnchor, constant: 14),
            skipCheckbox.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            skipCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            skipHint.topAnchor.constraint(equalTo: skipCheckbox.bottomAnchor, constant: 2),
            skipHint.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor, constant: 18),
            skipHint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            resumeCheckbox.topAnchor.constraint(equalTo: skipHint.bottomAnchor, constant: 10),
            resumeCheckbox.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            resumeCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            cwdLabel.topAnchor.constraint(equalTo: resumeCheckbox.bottomAnchor, constant: 24),
            cwdLabel.leadingAnchor.constraint(equalTo: cmdLabel.leadingAnchor),
            cwdLabel.widthAnchor.constraint(equalToConstant: 180),
            cwdField.centerYAnchor.constraint(equalTo: cwdLabel.centerYAnchor),
            cwdField.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            cwdField.trailingAnchor.constraint(equalTo: cwdPickBtn.leadingAnchor, constant: -8),
            cwdPickBtn.centerYAnchor.constraint(equalTo: cwdLabel.centerYAnchor),
            cwdPickBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            confirmCheckbox.topAnchor.constraint(equalTo: cwdField.bottomAnchor, constant: 24),
            confirmCheckbox.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            confirmCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            loginCheckbox.topAnchor.constraint(equalTo: confirmCheckbox.bottomAnchor, constant: 10),
            loginCheckbox.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor),
            loginCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            loginError.topAnchor.constraint(equalTo: loginCheckbox.bottomAnchor, constant: 4),
            loginError.leadingAnchor.constraint(equalTo: cmdPopup.leadingAnchor, constant: 18),
            loginError.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
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

        // — Terminal font —
        let fontLabel = NSTextField(labelWithString: "Terminal font")
        fontLabel.alignment = .right
        let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        fontPopup.addItem(withTitle: "Automatic (MesloLGS NF)")
        let families = NSFontManager.shared.availableFontFamilies
            .filter {
                guard let face = NSFontManager.shared.availableMembers(ofFontFamily: $0)?.first,
                      let name = face[0] as? String,
                      let f = NSFont(name: name, size: 13) else { return false }
                return f.isFixedPitch
            }
            .sorted()
        self.fontFamilies = families
        fontPopup.addItems(withTitles: families)
        let currentFontName = OpusPreferences.shared.fontName
        if let idx = families.firstIndex(of: currentFontName), !currentFontName.isEmpty {
            fontPopup.selectItem(at: idx + 1)
        } else {
            fontPopup.selectItem(at: 0)
        }
        fontPopup.target = self
        fontPopup.action = #selector(onFontFamilyChanged(_:))

        let sizeLabel = NSTextField(labelWithString: "Font size")
        sizeLabel.alignment = .right
        let sizeField = NSTextField(string: String(Int(OpusPreferences.shared.fontSize)))
        sizeField.alignment = .center
        let sizeFormatter = NumberFormatter()
        sizeFormatter.minimum = 9
        sizeFormatter.maximum = 24
        sizeFormatter.allowsFloats = false
        sizeField.formatter = sizeFormatter
        sizeField.target = self
        sizeField.action = #selector(onFontSizeSubmitted(_:))
        self.fontSizeField = sizeField

        let sizeStepper = NSStepper()
        sizeStepper.minValue = 9
        sizeStepper.maxValue = 24
        sizeStepper.increment = 1
        sizeStepper.integerValue = Int(OpusPreferences.shared.fontSize)
        sizeStepper.target = self
        sizeStepper.action = #selector(onFontSizeStepped(_:))
        self.fontSizeStepper = sizeStepper

        for v in [modeLabel, modePopup, tintLabel, tintWell, imgLabel, imgPath, imgPickBtn,
                  fontLabel, fontPopup, sizeLabel, sizeField, sizeStepper] {
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
            imgPickBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            fontLabel.topAnchor.constraint(equalTo: imgLabel.bottomAnchor, constant: 28),
            fontLabel.leadingAnchor.constraint(equalTo: modeLabel.leadingAnchor),
            fontLabel.widthAnchor.constraint(equalToConstant: 160),
            fontPopup.centerYAnchor.constraint(equalTo: fontLabel.centerYAnchor),
            fontPopup.leadingAnchor.constraint(equalTo: modePopup.leadingAnchor),
            fontPopup.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            sizeLabel.topAnchor.constraint(equalTo: fontLabel.bottomAnchor, constant: 20),
            sizeLabel.leadingAnchor.constraint(equalTo: modeLabel.leadingAnchor),
            sizeLabel.widthAnchor.constraint(equalToConstant: 160),
            sizeField.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizeField.leadingAnchor.constraint(equalTo: modePopup.leadingAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 48),
            sizeStepper.centerYAnchor.constraint(equalTo: sizeLabel.centerYAnchor),
            sizeStepper.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 4)
        ])

        refreshAppearanceVisibility(mode: currentMode)
        item.view = view
        return item
    }

    private func displayTab() -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "display")
        item.label = "Display"
        let view = NSView()

        let label = NSTextField(labelWithString: "Display mode")
        label.alignment = .right
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for mode in OpusDisplayMode.allCases {
            popup.addItem(withTitle: mode.displayName)
        }
        let current = OpusPreferences.shared.displayMode
        popup.selectItem(at: OpusDisplayMode.allCases.firstIndex(of: current) ?? 0)
        popup.target = self
        popup.action = #selector(onDisplayModeChanged(_:))

        let hint = NSTextField(wrappingLabelWithString:
            "All surfaces in the chosen mode share the same Claude session — " +
            "what you type in one shows everywhere. Restart Opus to apply changes.")
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

    @objc private func onDisplayModeChanged(_ sender: NSPopUpButton) {
        OpusPreferences.shared.displayMode = OpusDisplayMode.allCases[sender.indexOfSelectedItem]
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
        let isClaude = (preset == .claude)
        skipPermsCheckbox?.isHidden = !isClaude
        skipPermsHint?.isHidden = !isClaude
        resumeCheckbox?.isHidden = !isClaude
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

    @objc private func onSkipPermissionsToggled(_ sender: NSButton) {
        OpusPreferences.shared.skipPermissions = (sender.state == .on)
    }

    @objc private func onResumeToggled(_ sender: NSButton) {
        OpusPreferences.shared.resumeLastConversation = (sender.state == .on)
    }

    @objc private func onConfirmRestartToggled(_ sender: NSButton) {
        OpusPreferences.shared.confirmRestart = (sender.state == .on)
    }

    @objc private func onLaunchAtLoginToggled(_ sender: NSButton) {
        // Note: SMAppService needs the app at its final install location
        // (e.g. ~/Applications/). If launched translocated (e.g. straight
        // from Downloads), register() succeeds but the login item points to
        // the randomized path and won't fire after the app is moved.
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginErrorLabel?.isHidden = true
        } catch {
            loginErrorLabel?.stringValue =
                "Couldn't update login item: \(error.localizedDescription)"
            loginErrorLabel?.isHidden = false
            // Resync the checkbox with the system's actual state.
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
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

    @objc private func onFontFamilyChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        OpusPreferences.shared.fontName = (idx == 0) ? "" : fontFamilies[idx - 1]
    }

    @objc private func onFontSizeStepped(_ sender: NSStepper) {
        OpusPreferences.shared.fontSize = Double(sender.integerValue)
        fontSizeField?.stringValue = String(sender.integerValue)
    }

    @objc private func onFontSizeSubmitted(_ sender: NSTextField) {
        OpusPreferences.shared.fontSize = Double(sender.intValue)
        let clamped = Int(OpusPreferences.shared.fontSize)
        sender.stringValue = String(clamped)
        fontSizeStepper?.integerValue = clamped
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
        loginItemCheckbox?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        // The restart alert's "Don't ask again" can flip this behind our back.
        confirmRestartCheckbox?.state = OpusPreferences.shared.confirmRestart ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
