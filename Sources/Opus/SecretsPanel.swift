// SecretsPanel — Cmd+Ctrl+K. Copy a key, hit the hotkey, name it, Enter.
//
// Structural copy of PromptPalettePanel: NSPanel subclass with
// canBecomeKey true and canBecomeMain false, borderless nonactivating,
// .floating, forced .darkAqua, hudWindow blur under an opaque
// OpusTheme.panelBackground layer, window-scoped keyDown monitor, and
// previousKeyWindow captured on open and handed back on close.
//
// That last part is not decoration. Since the panel stopped autohiding on
// resign-key (commit 82021a0), a panel that does not hand key status back
// leaves the surface behind it visible but keyless, and the next keystroke
// goes to whatever application is frontmost.
//
// The value field is an NSSecureTextField and the row list shows only
// SecretExtractor.maskedPreview output, so the panel never renders a
// secret in full.

import AppKit
import OpusSecretsKit

private final class SecretsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SecretsPanel: NSObject {
    static let shared = SecretsPanel()

    private let panel: SecretsPanelWindow
    private let nameField = NSTextField()
    private let valueField = NSSecureTextField()
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let existingLabel = NSTextField(labelWithString: "")

    private let store = KeychainSecretStore()
    private var visible = false
    /// Bumped on every open() — a background store.names() load from an
    /// abandoned earlier open (rapid close/reopen) is dropped if it lands
    /// after a newer one has already started. Same pattern as
    /// PromptPalettePanel.scanGeneration.
    private var scanGeneration = 0
    private var keyMonitor: Any?
    private weak var previousKeyWindow: NSWindow?

    /// What the clipboard held when the panel opened. The clipboard is only
    /// cleared on a successful store, and only when it still holds this, so
    /// something copied in the meantime is never destroyed.
    private var capturedClipboard: String?
    private var candidates: [SecretCandidate] = []
    private var candidateIndex = 0
    private var pendingOverwrite: String?

    private override init() {
        let width: CGFloat = 520
        let height: CGFloat = 260

        panel = SecretsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovable = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.title = ""
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = OpusTheme.radiusPanel
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        let opaqueBG = NSView(frame: blur.bounds)
        opaqueBG.wantsLayer = true
        opaqueBG.layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        opaqueBG.layer?.cornerRadius = OpusTheme.radiusPanel
        opaqueBG.layer?.masksToBounds = true
        opaqueBG.autoresizingMask = [.width, .height]
        blur.addSubview(opaqueBG)

        super.init()

        let inset = OpusTheme.insetPanel
        let fieldWidth = width - inset * 2
        var y = height - 44

        let title = NSTextField(labelWithString: "Ranger un secret")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.textColor = OpusTheme.cream(0.95)
        title.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 20)
        blur.addSubview(title)
        y -= 40

        style(nameField, placeholder: "nom du secret (ex : resend-landing)")
        nameField.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 26)
        blur.addSubview(nameField)
        y -= 36

        style(valueField, placeholder: "valeur")
        valueField.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 26)
        blur.addSubview(valueField)
        y -= 26

        previewLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = OpusTheme.cyan
        previewLabel.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 18)
        blur.addSubview(previewLabel)
        y -= 30

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = OpusTheme.amber
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: inset, y: y, width: fieldWidth, height: 18)
        blur.addSubview(statusLabel)
        y -= 30

        existingLabel.font = NSFont.systemFont(ofSize: 11)
        existingLabel.textColor = OpusTheme.cream(0.5)
        existingLabel.lineBreakMode = .byTruncatingTail
        existingLabel.frame = NSRect(x: inset, y: inset, width: fieldWidth, height: y - inset)
        existingLabel.maximumNumberOfLines = 3
        blur.addSubview(existingLabel)

        nameField.delegate = self
        valueField.delegate = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.panel else { return ev }
            switch ev.keyCode {
            case 36:    // Return
                self.commit()
                return nil
            case 53:    // Escape
                self.close()
                return nil
            case 48:    // Tab through multiple extracted candidates
                guard self.candidates.count > 1 else { return ev }
                self.candidateIndex = (self.candidateIndex + 1) % self.candidates.count
                self.applyCandidate()
                return nil
            default:
                return ev
            }
        }
    }

    private func style(_ field: NSTextField, placeholder: String) {
        field.font = NSFont.systemFont(ofSize: 13)
        field.textColor = OpusTheme.cream(0.95)
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = OpusTheme.fieldBackground
        field.focusRingType = .none
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: OpusTheme.cream(0.4)]
        )
    }

    // MARK: Show/hide

    func toggle() { visible ? close() : open() }

    private func open() {
        let screen = activeScreen().frame
        let size = panel.frame.size
        panel.setFrame(
            NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                   width: size.width, height: size.height),
            display: false
        )

        nameField.stringValue = ""
        valueField.stringValue = ""
        previewLabel.stringValue = ""
        statusLabel.stringValue = ""
        pendingOverwrite = nil
        candidateIndex = 0

        captureClipboard()
        scanGeneration += 1
        refreshExistingNames(generation: scanGeneration)

        previousKeyWindow = NSApp.keyWindow
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(candidates.isEmpty ? valueField : nameField)
        visible = true
    }

    private func close() {
        visible = false
        // Never leave a secret sitting in a text field for the next open.
        valueField.stringValue = ""
        nameField.stringValue = ""
        capturedClipboard = nil
        candidates = []
        panel.orderOut(nil)
        if let previous = previousKeyWindow, previous.isVisible { previous.makeKey() }
        previousKeyWindow = nil
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // MARK: Clipboard

    private func captureClipboard() {
        let board = NSPasteboard.general
        // A file promise or an image is not a credential.
        guard board.data(forType: .fileURL) == nil, board.data(forType: .tiff) == nil,
              let text = board.string(forType: .string),
              text.utf8.count <= SecretExtractor.maximumBlobBytes
        else { return }

        capturedClipboard = text
        candidates = SecretExtractor.candidates(from: text)
        if !candidates.isEmpty { applyCandidate() }
    }

    private func applyCandidate() {
        // Setting stringValue programmatically does not fire the delegate, so
        // a confirmation armed for an earlier candidate would survive a Tab
        // cycle and let Return overwrite with no warning shown.
        pendingOverwrite = nil
        let candidate = candidates[candidateIndex]
        nameField.stringValue = candidate.suggestedName
        valueField.stringValue = candidate.value
        updatePreview()
        if candidates.count > 1 {
            statusLabel.stringValue = "\(candidateIndex + 1)/\(candidates.count) extraits du presse-papier. Tab pour le suivant."
        }
    }

    private func updatePreview() {
        let value = valueField.stringValue
        guard !value.isEmpty else { previewLabel.stringValue = ""; return }
        previewLabel.stringValue = "sera rangé : " + SecretExtractor.maskedPreview(value)

        if SecretExtractor.isShellHostile(value) {
            statusLabel.stringValue = "contient des caractères que le shell interprète : utiliser « opus-secrets run »."
        } else if value.count < SecretRedactor.minimumRedactableLength {
            statusLabel.stringValue = "trop courte pour la redaction automatique."
        } else if candidates.count <= 1 {
            statusLabel.stringValue = ""
        }
    }

    private func refreshExistingNames(generation: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let names = (try? self.store.names()) ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.scanGeneration == generation else { return }
                self.existingLabel.stringValue = names.isEmpty
                    ? "aucun secret rangé"
                    : "déjà rangés : " + names.joined(separator: ", ")
            }
        }
    }

    // MARK: Commit

    private func commit() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let value = valueField.stringValue

        guard !value.isEmpty else {
            statusLabel.stringValue = "valeur vide."
            return
        }
        guard SecretName.isValid(name) else {
            statusLabel.stringValue = name.isEmpty
                ? "il manque un nom."
                : "nom invalide. minuscules, chiffres, point et tiret, 64 max."
            return
        }

        let existing: [String]
        do {
            existing = try store.names()
        } catch {
            // Fail CLOSED. Without the name list there is no way to tell an
            // overwrite from a first write, and `put` uses -U so it would
            // replace in place with no warning at all. Refusing is annoying
            // and recoverable; a silent overwrite is neither.
            statusLabel.stringValue = "\(error)"
            return
        }
        if existing.contains(name), pendingOverwrite != name {
            pendingOverwrite = name
            statusLabel.stringValue = "« \(name) » existe déjà. Entrée à nouveau pour écraser."
            return
        }

        do {
            try store.put(name: name, value: value)
        } catch {
            statusLabel.stringValue = "échec de l'enregistrement : \(error)"
            return
        }

        // Only clear the clipboard when it still holds what we captured.
        if let captured = capturedClipboard,
           NSPasteboard.general.string(forType: .string) == captured {
            NSPasteboard.general.clearContents()
        }

        close()
    }
}

extension SecretsPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === valueField else {
            pendingOverwrite = nil
            statusLabel.stringValue = ""
            return
        }
        updatePreview()
    }
}
