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
// The value field is an NSSecureTextField and, by default, the row list
// below it shows only SecretExtractor.maskedPreview output, so the panel
// never renders a secret in full unless Cmd+R is held down to ask for it —
// see toggleReveal().
//
// The list exists because depositing blind, with several keys already
// stored, invites near-duplicates ("stripe-key" vs "stripe-live") that are
// only noticed later. It lives at the bottom of THIS panel rather than a
// second one so it is visible at the exact moment it matters: while typing
// the new name. Up/Down browse it without stealing focus from the name
// field (see moveSecretSelection) — there is deliberately no Enter-on-row
// action, no delete, no rename; this is read-only company for typing, not
// a second management surface (those already exist: `secret rm`/`rename`).
//
// commit() no longer closes the panel on success — it resets the fields
// and refreshes the list in place, because storing several keys in one
// sitting is the whole reason the list is here. Escape still closes.

import AppKit
import OpusSecretsKit

private final class SecretsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One row of the "already stored" list: a name and its real value. The
/// value is held in memory only while the panel is open — wiped (rows =
/// []) on close(), same hygiene as the value fields themselves.
private struct SecretRow {
    let name: String
    let value: String
}

/// Selected-row background: translucent brand-cyan fill + a 2pt left accent
/// stripe. Same treatment as PromptPalettePanel's PromptRowBackground (that
/// type is file-private to PromptPalettePanel.swift, so this is a
/// same-pattern copy, not a shared type) — keeps this list's selection
/// reading as the same app feature as the prompt palette's.
private final class SecretRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 4, dy: 1)
        OpusTheme.cyan.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        let stripe = NSRect(x: r.minX, y: r.minY, width: 2, height: r.height)
        OpusTheme.cyan.withAlphaComponent(0.6).setFill()
        NSBezierPath(rect: stripe).fill()
    }
}

/// One row: the secret's name on the left, its masked (or, with Cmd+R held,
/// full) value in a fixed-width monospaced block pinned to the trailing
/// edge. Every row's value starts at the same x regardless of name length —
/// real column alignment via a fixed constant, not manual string padding.
private final class SecretRowCellView: NSTableCellView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = OpusTheme.cream(0.85)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isSelectable = false
        nameLabel.refusesFirstResponder = true

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = OpusTheme.cream(0.55)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.isSelectable = false
        valueLabel.refusesFirstResponder = true

        addSubview(nameLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -12),

            valueLabel.widthAnchor.constraint(equalToConstant: 170),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(name: String, displayValue: String) {
        nameLabel.stringValue = name
        valueLabel.stringValue = displayValue
    }
}

final class SecretsPanel: NSObject {
    static let shared = SecretsPanel()

    private static let rowCellID = NSUserInterfaceItemIdentifier("SecretRow")

    private let panel: SecretsPanelWindow
    private let nameField = NSTextField()
    private let valueField = NSSecureTextField()
    /// Stacked in the exact same frame as valueField, hidden unless Cmd+R
    /// is on. NSSecureTextField cannot be switched to plain text in place,
    /// so this is the usual AppKit workaround: two fields, one frame, only
    /// one ever visible. Kept mirrored with valueField on every keystroke
    /// (see controlTextDidChange) so toggling never drops or duplicates
    /// what's been typed, and both are wiped on close() regardless of
    /// which was showing.
    private let valueFieldPlain = NSTextField()
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// "déjà rangés (N)" normally; the store's own problem text, in red,
    /// when names() or a value read failed — never silently rendered as an
    /// empty list.
    private let listHeaderLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView(frame: .zero)

    private let store = KeychainSecretStore()
    private var visible = false
    /// Bumped on every open() AND on every successful commit() — a
    /// background store read from an abandoned earlier request (rapid
    /// close/reopen, or a second deposit made before the first read
    /// landed) is dropped if it resolves after a newer one has already
    /// started. Same pattern as PromptPalettePanel.scanGeneration.
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

    /// The already-stored secrets, name-sorted, as loaded by the most
    /// recent refreshSecrets() to land. Backs the table view.
    private var rows: [SecretRow] = []
    /// Cmd+R: off by default, always reset on open()/close(). When on, the
    /// value field shows plain text and every row shows its full value.
    private var revealed = false

    private override init() {
        let width: CGFloat = 520
        let height: CGFloat = 460

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

        style(valueFieldPlain, placeholder: "valeur")
        valueFieldPlain.frame = valueField.frame
        valueFieldPlain.isHidden = true
        blur.addSubview(valueFieldPlain)
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

        listHeaderLabel.font = NSFont.systemFont(ofSize: 11)
        listHeaderLabel.textColor = OpusTheme.cream(0.5)
        listHeaderLabel.lineBreakMode = .byTruncatingTail
        listHeaderLabel.frame = NSRect(x: inset, y: y - 20, width: fieldWidth, height: 20)
        blur.addSubview(listHeaderLabel)
        y -= 28

        let scroll = NSScrollView(frame: NSRect(x: inset, y: inset, width: fieldWidth, height: y - inset))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("secret"))
        column.width = fieldWidth - 16
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 22
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        // See PromptPalettePanel's own table for why `.regular` (not
        // `.none`) is required for a view-based table even though
        // SecretRowBackground fully owns the drawn appearance regardless.
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        scroll.documentView = tableView
        blur.addSubview(scroll)

        nameField.delegate = self
        valueField.delegate = self
        valueFieldPlain.delegate = self
        tableView.delegate = self
        tableView.dataSource = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.panel else { return ev }
            // Letter shortcut matched by character, not keyCode — same
            // convention as main.swift's Cmd+letter handling (AZERTY etc.
            // put letters in the same place as QWERTY; digits don't).
            if KeyMods.shortcutMods(ev.modifierFlags) == .command,
               ev.charactersIgnoringModifiers?.lowercased() == "r" {
                self.toggleReveal()
                return nil
            }
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
            case 125:   // Down arrow — browse the stored-secrets list.
                self.moveSecretSelection(by: 1)
                return nil
            case 126:   // Up arrow — same, upward. Neither moves first
                        // responder: whichever field was being typed into
                        // (normally nameField) keeps it, exactly like
                        // PromptPalettePanel's own Up/Down.
                self.moveSecretSelection(by: -1)
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
        valueFieldPlain.stringValue = ""
        previewLabel.stringValue = ""
        statusLabel.stringValue = ""
        pendingOverwrite = nil
        candidateIndex = 0

        // Reveal always starts OFF, regardless of how it was left before —
        // close() already resets this, but a fresh open() asserts it too
        // rather than trusting that every path into "not visible" went
        // through close().
        revealed = false
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        rows = []
        tableView.reloadData()

        captureClipboard()
        scanGeneration += 1
        refreshSecrets(generation: scanGeneration)

        previousKeyWindow = NSApp.keyWindow
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(candidates.isEmpty ? valueField : nameField)
        visible = true
    }

    private func close() {
        visible = false
        // Never leave a secret sitting in a text field for the next open.
        // The plain reveal field is exactly as sensitive as the secure one
        // it stands in for, so it gets the same wipe, and reveal itself is
        // reset so the panel never reopens already showing values.
        valueField.stringValue = ""
        valueFieldPlain.stringValue = ""
        nameField.stringValue = ""
        capturedClipboard = nil
        candidates = []
        revealed = false
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        rows = []
        tableView.reloadData()
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
        valueFieldPlain.stringValue = candidate.value
        updatePreview()
        if candidates.count > 1 {
            statusLabel.stringValue = "\(candidateIndex + 1)/\(candidates.count) extraits du presse-papier. Tab pour le suivant."
        }
    }

    private func updatePreview() {
        let value = valueField.stringValue
        guard !value.isEmpty else { previewLabel.stringValue = ""; return }

        // The panel's whole principle is that the user sees what will
        // actually happen before it happens, so the name shown here is the
        // SLUGGED form commit() will actually store under, not the raw text
        // sitting in the field — recomputed on every keystroke in either
        // field, never written back into nameField itself.
        let maskedValue = SecretExtractor.maskedPreview(value)
        let slugged = SecretName.slug(nameField.stringValue)
        previewLabel.stringValue = slugged.isEmpty
            ? "sera rangé : " + maskedValue
            : "sera rangé sous « \(slugged) » : " + maskedValue

        if SecretExtractor.isShellHostile(value) {
            statusLabel.stringValue = "contient des caractères que le shell interprète : utiliser « opus-secrets run »."
        } else if value.count < SecretRedactor.minimumRedactableLength {
            statusLabel.stringValue = "trop courte pour la redaction automatique."
        } else if candidates.count <= 1 {
            statusLabel.stringValue = ""
        }
    }

    // MARK: Stored-secrets list

    /// Reads every stored name AND value, concurrently, on the same
    /// background queue that used to just read names. Each
    /// KeychainSecretStore.value(for:) spawns /usr/bin/security at a
    /// measured ~23 ms, so reading N secrets sequentially would leave the
    /// list empty for N × 23 ms on every open. Concurrent, with an NSLock
    /// around the shared collections, is the same shape as
    /// HookRunner.runPost and PromptPalettePanel.open() — this file's own
    /// scanGeneration guard already existed for exactly this kind of
    /// background load.
    private func refreshSecrets(generation: Int) {
        // Snapshot now, not inside the background block: install() runs
        // once at launch (main.swift), so lastProblem is already settled by
        // the time the panel can open.
        let installerProblem = SecretsInstaller.lastProblem

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Never report a failed read as an empty store: this is the
            // exact lie already fixed for `opus-secrets ls` (a locked
            // Keychain must not render as "rien n'est rangé"), and a list
            // that just goes quiet here would be the same failure with a
            // different audience.
            var namesProblem: String?
            let names: [String]
            do {
                names = try self.store.names()
            } catch {
                names = []
                namesProblem = "\(error)"
            }

            var pairs: [(name: String, value: String)] = []
            var unreadable: [String] = []
            if !names.isEmpty {
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: names.count) { index in
                    let name = names[index]
                    if let value = try? self.store.value(for: name) {
                        lock.lock(); pairs.append((name: name, value: value)); lock.unlock()
                    } else {
                        lock.lock(); unreadable.append(name); lock.unlock()
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, self.scanGeneration == generation else { return }
                self.renderSecrets(pairs: pairs, installerProblem: installerProblem,
                                    namesProblem: namesProblem, unreadable: unreadable)
            }
        }
    }

    /// Three independent problems can coexist (hooks never installed, a
    /// locked Keychain, and a handful of individually-unreadable items), so
    /// all of them are shown, joined, in OpusTheme.red — unmissable, and
    /// distinct from the dim cream this label otherwise uses for the
    /// ordinary "déjà rangés (N)" count. Whatever WAS readable still
    /// populates the table below; only the header line reports the problem.
    private func renderSecrets(pairs: [(name: String, value: String)], installerProblem: String?,
                                namesProblem: String?, unreadable: [String]) {
        rows = pairs
            .map { SecretRow(name: $0.name, value: $0.value) }
            .sorted { $0.name < $1.name }
        tableView.reloadData()

        var problems: [String] = []
        if let installerProblem {
            problems.append("hooks de secrets non installés : \(installerProblem)")
        }
        if let namesProblem {
            problems.append("Trousseau illisible : \(namesProblem)")
        }
        if !unreadable.isEmpty {
            problems.append("valeur illisible pour \(unreadable.count) secret(s) : \(unreadable.sorted().joined(separator: ", "))")
        }
        guard problems.isEmpty else {
            listHeaderLabel.textColor = OpusTheme.red
            listHeaderLabel.stringValue = problems.joined(separator: " · ")
            return
        }
        listHeaderLabel.textColor = OpusTheme.cream(0.5)
        listHeaderLabel.stringValue = rows.isEmpty
            ? "aucun secret rangé"
            : "déjà rangés (\(rows.count))"
    }

    private func moveSecretSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Cmd+R: one key, one idea — show the values instead of dots/masks,
    /// everywhere at once (the field being typed into AND every row
    /// below). See valueFieldPlain's doc comment for why a second field
    /// exists instead of reconfiguring valueField in place.
    private func toggleReveal() {
        revealed.toggle()

        let wasEditingSecure = valueField.currentEditor() != nil
        let wasEditingPlain = valueFieldPlain.currentEditor() != nil

        valueField.isHidden = revealed
        valueFieldPlain.isHidden = !revealed

        // If the value field itself had focus, hand it to whichever of the
        // pair is now visible so typing keeps working uninterrupted. If
        // focus was elsewhere (typically nameField), leave it there — this
        // toggle never moves focus on its own.
        if revealed, wasEditingSecure {
            panel.makeFirstResponder(valueFieldPlain)
        } else if !revealed, wasEditingPlain {
            panel.makeFirstResponder(valueField)
        }

        tableView.reloadData()
    }

    // MARK: Commit

    private func commit() {
        // The user types roughly ("stripe key", "RESEND_API_KEY") and the
        // panel normalizes rather than rejecting: slug() is the same
        // normalization already applied to labels extracted from the
        // clipboard, now also applied to a hand-typed name. The field
        // itself is never rewritten (see updatePreview): only the stored
        // name is the slugged one.
        let typedName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let name = SecretName.slug(typedName)
        let value = valueField.stringValue

        guard !value.isEmpty else {
            statusLabel.stringValue = "valeur vide."
            return
        }
        guard !name.isEmpty else {
            statusLabel.stringValue = typedName.isEmpty
                ? "il manque un nom."
                : "ce nom ne contient aucun caractère utilisable."
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

        // Stay open rather than close. Storing several keys in one sitting
        // while checking the list for near-duplicates is the entire reason
        // the list lives here (see the file's header comment) — closing
        // now would mean the list update this very commit triggers is
        // never actually seen. Reset for the next name; Escape still
        // closes when the user is done.
        nameField.stringValue = ""
        valueField.stringValue = ""
        valueFieldPlain.stringValue = ""
        previewLabel.stringValue = ""
        statusLabel.stringValue = ""
        pendingOverwrite = nil
        candidates = []
        candidateIndex = 0
        capturedClipboard = nil
        scanGeneration += 1
        refreshSecrets(generation: scanGeneration)
        panel.makeFirstResponder(nameField)
    }
}

extension SecretsPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        // valueField and valueFieldPlain mirror each other on every
        // keystroke so Cmd+R can swap which one is visible without ever
        // losing or duplicating what's been typed (see toggleReveal).
        // Setting stringValue programmatically does not itself trigger
        // this notification (see applyCandidate's comment above), so
        // there is no feedback loop between the two `if` branches below.
        if field === valueField {
            valueFieldPlain.stringValue = valueField.stringValue
        } else if field === valueFieldPlain {
            valueField.stringValue = valueFieldPlain.stringValue
        }

        // Editing the name only ever invalidates the "« name » existe déjà"
        // overwrite prompt, which is tied to the specific name it warned
        // about — never the value's own shell-hostility/too-short warning,
        // which has nothing to do with the name and used to be wiped out by
        // this same branch, silently dropping the one signal that a value
        // will break its command. updatePreview() recomputes statusLabel
        // from the CURRENT value either way, so it both restores a live
        // value warning and clears a now-stale overwrite prompt.
        if field !== valueField && field !== valueFieldPlain {
            pendingOverwrite = nil
        }
        updatePreview()
    }
}

extension SecretsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let secret = rows[row]
        let cell: SecretRowCellView
        if let reused = tableView.makeView(withIdentifier: Self.rowCellID, owner: self) as? SecretRowCellView {
            cell = reused
        } else {
            cell = SecretRowCellView()
            cell.identifier = Self.rowCellID
        }
        let displayValue = revealed ? secret.value : SecretExtractor.maskedPreview(secret.value)
        cell.configure(name: secret.name, displayValue: displayValue)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SecretRowBackground()
    }
}
