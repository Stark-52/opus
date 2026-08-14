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
// goes to whatever application is frontmost. Now that open/close animate
// (see animateAppear/animateDismiss), that handback happens BEFORE the
// dismiss fade starts, not when it finishes — the window can keep fading
// on screen for 90ms after focus has already gone home.
//
// The value field is an NSSecureTextField and, by default, the row list
// below it shows only SecretExtractor.maskedValue output, so the panel
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
// commit() closes the panel only once there is no more clipboard candidate
// left to walk through — see the MARK: Commit section. Escape is
// progressive: it clears an active filter before it closes the panel.
//
// The panel is sized to its content (see relayout) rather than fixed, and
// grows/shrinks instantly (no animation) as the filtered list changes
// length; the only things that animate are the panel appearing and
// disappearing as a whole (see animateAppear/animateDismiss).

import AppKit
import OpusSecretsKit

private final class SecretsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One row of the "already stored" list: a name and its real value. The
/// value is held in memory only while the panel is open — wiped on
/// close(), same hygiene as the value fields themselves.
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

/// Three left-aligned, fixed-width columns: name, then the masked-or-
/// revealed value in a monospaced font, then its length. Name and value
/// each get a hard width via NSLayoutConstraint (not intrinsic sizing), so
/// a long value truncates inside its own lane and can never borrow space
/// from — or squeeze — the name column. The name is what's being scanned
/// for; it is the one thing here that must stay readable.
private final class SecretRowCellView: NSTableCellView {
    static let nameColumnWidth: CGFloat = 150
    static let valueColumnWidth: CGFloat = 190

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = OpusTheme.cream(0.85)
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.isSelectable = false
        nameLabel.refusesFirstResponder = true

        valueLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = OpusTheme.cream(0.6)
        valueLabel.alignment = .left
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.isSelectable = false
        valueLabel.refusesFirstResponder = true

        lengthLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        lengthLabel.textColor = OpusTheme.cream(0.4)
        lengthLabel.alignment = .left
        lengthLabel.lineBreakMode = .byTruncatingTail
        lengthLabel.translatesAutoresizingMaskIntoConstraints = false
        lengthLabel.isSelectable = false
        lengthLabel.refusesFirstResponder = true

        addSubview(nameLabel)
        addSubview(valueLabel)
        addSubview(lengthLabel)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.nameColumnWidth),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            valueLabel.widthAnchor.constraint(equalToConstant: Self.valueColumnWidth),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            lengthLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 10),
            lengthLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            lengthLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(name: String, displayValue: String, length: String) {
        nameLabel.stringValue = name
        valueLabel.stringValue = displayValue
        lengthLabel.stringValue = length
    }
}

final class SecretsPanel: NSObject {
    static let shared = SecretsPanel()

    private static let rowCellID = NSUserInterfaceItemIdentifier("SecretRow")
    /// Width never changes — only height, via relayout(), as the filtered
    /// list grows or shrinks.
    private static let width: CGFloat = 520
    private static let topMargin: CGFloat = 24

    private let panel: SecretsPanelWindow
    private let titleLabel = NSTextField(labelWithString: "Ranger un secret")
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
    /// previewLabel and statusLabel each have a fixed frame height (18pt)
    /// that never changes with their content — empty string still reserves
    /// the row — so nothing below them shifts as the user types.
    private let previewLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    /// One point, OpusTheme.cream at low alpha, full width: the only thing
    /// marking where "depositing" ends and "browsing what's already there"
    /// begins.
    private let separator = NSView()
    /// Filters the list below by NAME only — never by value, which would
    /// make a search box behave differently depending on whether reveal is
    /// on, a surprising thing for a search box to do.
    private let searchField = NSSearchField()
    /// "N secret(s)" or "F sur N" while filtering; the store's own problem
    /// text, in red, when names() or a value read failed — never silently
    /// rendered as an empty list.
    private let listHeaderLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let tableView = NSTableView(frame: .zero)
    /// State-aware, not a static legend: "⌘R révéler" in the dim
    /// treatment, "⌘R masquer" in OpusTheme.amber once reveal is actually
    /// on, so a panel left open with values showing keeps announcing it.
    private let hintLabel = NSTextField(labelWithString: "")

    private let store = KeychainSecretStore()
    private var visible = false
    /// Bumped on every open() AND on every successful commit() that
    /// refreshes the list — a background store read from an abandoned
    /// earlier request (rapid close/reopen, or a second deposit made
    /// before the first read landed) is dropped if it resolves after a
    /// newer one has already started. Same pattern as
    /// PromptPalettePanel.scanGeneration.
    private var scanGeneration = 0
    private var keyMonitor: Any?
    private weak var previousKeyWindow: NSWindow?

    /// What the clipboard held when the panel opened. The clipboard is only
    /// cleared on the FIRST successful store of a multi-candidate paste,
    /// and only when it still holds this, so something copied in the
    /// meantime is never destroyed. Never re-read mid-session — the
    /// remaining candidates already live in `candidates`.
    private var capturedClipboard: String?
    private var candidates: [SecretCandidate] = []
    private var candidateIndex = 0
    private var pendingOverwrite: String?

    /// Every secret loaded from the Keychain, name-sorted.
    private var rows: [SecretRow] = []
    /// `rows` narrowed by searchField's text — what actually backs the
    /// table and what Up/Down browse.
    private var filteredSecrets: [SecretRow] = []
    /// Set by the most recent renderSecrets(); overrides the count in
    /// listHeaderLabel with the problem text, in red, until a read
    /// succeeds cleanly again.
    private var storeProblem: String?
    /// Cmd+R: off by default, always reset on open()/close(). When on, the
    /// value field shows plain text and every row shows its full value.
    private var revealed = false
    /// Screen-space Y of the panel's top edge, set whenever relayout()
    /// centers the panel (open()) and preserved across every subsequent
    /// relayout() so the deposit block above the list never itself moves
    /// as the list grows or shrinks — only the window's bottom edge does.
    private var panelTopY: CGFloat = 0

    private override init() {
        panel = SecretsPanelWindow(
            // Placeholder size only — relayout() sizes and positions the
            // panel for real before it is ever shown.
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 460),
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
        // AppKit's own implicit ordering animation is turned off — the
        // panel's appear/dismiss motion is driven explicitly instead (see
        // animateAppear/animateDismiss), so the two must never both fire.
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.title = ""
        panel.appearance = NSAppearance(named: .darkAqua)

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 460))
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

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = OpusTheme.cream(0.95)
        blur.addSubview(titleLabel)

        style(nameField, placeholder: "nom du secret (ex : resend-landing)")
        blur.addSubview(nameField)

        style(valueField, placeholder: "valeur")
        blur.addSubview(valueField)

        style(valueFieldPlain, placeholder: "valeur")
        valueFieldPlain.isHidden = true
        blur.addSubview(valueFieldPlain)

        previewLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = OpusTheme.cyan
        blur.addSubview(previewLabel)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = OpusTheme.amber
        statusLabel.lineBreakMode = .byTruncatingTail
        blur.addSubview(statusLabel)

        separator.wantsLayer = true
        separator.layer?.backgroundColor = OpusTheme.cream(0.12).cgColor
        blur.addSubview(separator)

        style(searchField, placeholder: "filtrer")
        blur.addSubview(searchField)

        listHeaderLabel.font = NSFont.systemFont(ofSize: 11)
        listHeaderLabel.textColor = OpusTheme.cream(0.5)
        listHeaderLabel.lineBreakMode = .byTruncatingTail
        blur.addSubview(listHeaderLabel)

        scrollView.autoresizingMask = []
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("secret"))
        column.width = Self.width - OpusTheme.insetPanel * 2 - 16
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
        scrollView.documentView = tableView
        blur.addSubview(scrollView)

        hintLabel.lineBreakMode = .byTruncatingTail
        blur.addSubview(hintLabel)

        nameField.delegate = self
        valueField.delegate = self
        valueFieldPlain.delegate = self
        searchField.delegate = self
        tableView.delegate = self
        tableView.dataSource = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.panel else { return ev }
            // Letter shortcuts matched by character, not keyCode — same
            // convention as main.swift's Cmd+letter handling and
            // FindBarView's own Cmd+F (AZERTY etc. put letters in the same
            // place as QWERTY; digits don't).
            if KeyMods.shortcutMods(ev.modifierFlags) == .command {
                switch ev.charactersIgnoringModifiers?.lowercased() {
                case "r":
                    self.toggleReveal()
                    return nil
                case "f":
                    self.panel.makeFirstResponder(self.searchField)
                    return nil
                default:
                    break
                }
            }
            switch ev.keyCode {
            case 36:    // Return
                self.commit()
                return nil
            case 53:    // Escape — progressive, see handleEscape().
                self.handleEscape()
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

    // MARK: Layout

    /// Lays out every subview top-down and sizes the panel to exactly what
    /// that content needs, then positions the window. `recenter: true`
    /// (open() only) centers the panel on the active screen using the
    /// freshly computed height and remembers the resulting top edge in
    /// panelTopY; every other call keeps that top edge fixed and only
    /// moves the BOTTOM edge, so the deposit block above the list never
    /// itself shifts as filtering grows or shrinks the list underneath it
    /// — only the window's own origin and the list's height change.
    ///
    /// Two passes: first walk top-down accumulating each element's
    /// distance from the top (independent of the panel's own height, which
    /// isn't known yet — computing it is the whole point of this pass),
    /// then convert every one of those into an actual frame.y once the
    /// total, and therefore the panel height, is known.
    private func relayout(recenter: Bool) {
        let inset = OpusTheme.insetPanel
        let fieldWidth = Self.width - inset * 2

        // Capped at 8 rows tall (scrolling handles the rest) but never
        // less than 1 row's worth of space, even at zero results, so the
        // list area is never a jarring zero-height sliver.
        let visibleRowCount = min(max(filteredSecrets.count, 1), 8)
        let listHeight = CGFloat(visibleRowCount) * (tableView.rowHeight + tableView.intercellSpacing.height)

        var distanceFromTop: CGFloat = Self.topMargin
        var stacked: [(view: NSView, y0: CGFloat, height: CGFloat)] = []
        func stack(_ view: NSView, height: CGFloat, gapAfter: CGFloat) {
            stacked.append((view, distanceFromTop, height))
            distanceFromTop += height + gapAfter
        }

        stack(titleLabel, height: 20, gapAfter: 20)
        stack(nameField, height: 26, gapAfter: 10)
        stack(valueField, height: 26, gapAfter: 12)
        stack(previewLabel, height: 18, gapAfter: 6)
        stack(statusLabel, height: 18, gapAfter: 12)
        stack(separator, height: 1, gapAfter: 12)
        stack(searchField, height: 26, gapAfter: 8)
        stack(listHeaderLabel, height: 20, gapAfter: 8)
        stack(scrollView, height: listHeight, gapAfter: 8)
        stack(hintLabel, height: 18, gapAfter: 0)

        let newHeight = distanceFromTop + inset

        for (view, y0, height) in stacked {
            view.frame = NSRect(x: inset, y: newHeight - y0 - height, width: fieldWidth, height: height)
        }
        valueFieldPlain.frame = valueField.frame

        let originX: CGFloat
        let originY: CGFloat
        if recenter {
            let screen = activeScreen().frame
            originX = screen.midX - Self.width / 2
            originY = screen.midY - newHeight / 2
        } else {
            originX = panel.frame.origin.x
            originY = panelTopY - newHeight
        }
        // Never animated — only the panel appearing/disappearing as a
        // whole does (see animateAppear/animateDismiss). A list that grows
        // or shrinks as you type a filter should snap, not glide.
        panel.setFrame(NSRect(x: originX, y: originY, width: Self.width, height: newHeight), display: true)
        panelTopY = originY + newHeight
    }

    // MARK: Show/hide

    func toggle() { visible ? close() : open() }

    private func open() {
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
        storeProblem = nil
        searchField.stringValue = ""
        applyFilter()
        relayout(recenter: true)

        captureClipboard()
        scanGeneration += 1
        refreshSecrets(generation: scanGeneration)

        previousKeyWindow = NSApp.keyWindow
        animateAppear()
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
        candidateIndex = 0
        revealed = false
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        rows = []
        filteredSecrets = []
        storeProblem = nil
        searchField.stringValue = ""
        tableView.reloadData()

        // Hand focus back FIRST, synchronously, never gated behind the
        // dismiss animation below. The window is free to keep fading on
        // screen for another 90ms; the surface the user is about to type
        // into again must be key the instant this runs, or keystrokes
        // typed right after are lost.
        if let previous = previousKeyWindow, previous.isVisible { previous.makeKey() }
        previousKeyWindow = nil

        animateDismiss { [weak self] in
            // Guard against a rapid close-then-reopen: if a new open() has
            // already made the panel visible again by the time this fires,
            // ordering it out now would hide the freshly reopened panel.
            guard let self, !self.visible else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: Appear/dismiss animation

    /// Opacity 0→1 with a micro-scale from 0.97, ~140ms ease-out, scaled
    /// about the panel's centre (CALayer's default anchorPoint is already
    /// (0.5, 0.5), so no anchor adjustment is needed — only a transform on
    /// a layer whose position already sits at its frame's centre avoids
    /// the drift a corner-anchored scale would produce). Key status and
    /// first responder are set by the caller (open()) BEFORE this runs, so
    /// every keystroke lands from the first frame regardless of how far
    /// the animation has gotten.
    private func animateAppear() {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            panel.makeKey()
            return
        }
        layer.removeAnimation(forKey: "dismissScale")

        panel.alphaValue = 0
        layer.transform = CATransform3DMakeScale(0.97, 0.97, 1)
        panel.orderFrontRegardless()
        panel.makeKey()

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DMakeScale(0.97, 0.97, 1)
        scale.toValue = CATransform3DIdentity
        scale.duration = 0.14
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.transform = CATransform3DIdentity
        layer.add(scale, forKey: "appearScale")

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    /// Faster than the appearance (a dismissal that takes as long as an
    /// appearance feels sluggish): opacity 1→0, scale down to 0.98, ~90ms
    /// ease-in. Purely visual — focus has already moved on by the time
    /// this is called (see close()); `completion` only orders the window
    /// out once it has finished fading, it does not gate anything
    /// input-related.
    private func animateDismiss(completion: @escaping () -> Void) {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 0
            completion()
            return
        }
        layer.removeAnimation(forKey: "appearScale")

        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity
        scale.toValue = CATransform3DMakeScale(0.98, 0.98, 1)
        scale.duration = 0.09
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        layer.add(scale, forKey: "dismissScale")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // MARK: Escape

    /// If the filter has text, Escape clears it and returns focus to the
    /// name field — one gesture to get back to a clean deposit, not two.
    /// Only an EMPTY filter lets Escape close the panel, matching how it
    /// always has.
    private func handleEscape() {
        guard searchField.stringValue.isEmpty else {
            searchField.stringValue = ""
            applyFilter()
            relayout(recenter: false)
            panel.makeFirstResponder(nameField)
            return
        }
        close()
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
    /// locked Keychain, and a handful of individually-unreadable items) —
    /// stored in `storeProblem` and reported, joined, in OpusTheme.red by
    /// updateListHeader(), unmissable and distinct from the dim cream that
    /// label otherwise uses for the ordinary count. Whatever WAS readable
    /// still populates the table below; only the header line reports the
    /// problem.
    private func renderSecrets(pairs: [(name: String, value: String)], installerProblem: String?,
                                namesProblem: String?, unreadable: [String]) {
        rows = pairs
            .map { SecretRow(name: $0.name, value: $0.value) }
            .sorted { $0.name < $1.name }

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
        storeProblem = problems.isEmpty ? nil : problems.joined(separator: " · ")

        applyFilter()
        relayout(recenter: false)
    }

    /// Recomputes filteredSecrets from `rows` and searchField's text (name
    /// match only — see searchField's own doc comment for why values are
    /// never searched), reloads the table, and refreshes the header/hint
    /// text. Does NOT resize the panel; callers that can change row COUNT
    /// (open(), a filter edit, a fresh Keychain read) follow this with
    /// relayout(recenter:) themselves.
    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredSecrets = query.isEmpty ? rows : rows.filter { $0.name.lowercased().contains(query) }
        tableView.reloadData()
        updateListHeader(filterActive: !query.isEmpty)
        updateHint()
    }

    private func updateListHeader(filterActive: Bool) {
        if let storeProblem {
            listHeaderLabel.textColor = OpusTheme.red
            listHeaderLabel.stringValue = storeProblem
            return
        }
        listHeaderLabel.textColor = OpusTheme.cream(0.5)
        if rows.isEmpty {
            listHeaderLabel.stringValue = "aucun secret rangé"
        } else if filterActive {
            listHeaderLabel.stringValue = "\(filteredSecrets.count) sur \(rows.count)"
        } else {
            listHeaderLabel.stringValue = rows.count > 1 ? "\(rows.count) secrets" : "1 secret"
        }
    }

    /// State-aware, not a static legend. "↑↓ parcourir" is only advertised
    /// when there's something to browse (matches moveSecretSelection's own
    /// guard); "⌘R révéler"/"⌘R masquer" swap text AND color depending on
    /// whether values are currently showing, so a panel left open with
    /// reveal on keeps announcing it rather than reading as a static
    /// legend once the moment that mattered has passed.
    private func updateHint() {
        let font = NSFont.systemFont(ofSize: 11)
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: OpusTheme.cream(0.5), .font: font]
        let warn: [NSAttributedString.Key: Any] = [.foregroundColor: OpusTheme.amber, .font: font]

        let attr = NSMutableAttributedString()
        func addSegment(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            if attr.length > 0 {
                attr.append(NSAttributedString(string: " · ", attributes: dim))
            }
            attr.append(NSAttributedString(string: text, attributes: attrs))
        }
        if !filteredSecrets.isEmpty {
            addSegment("↑↓ parcourir", dim)
        }
        addSegment("⌘F filtrer", dim)
        addSegment(revealed ? "⌘R masquer" : "⌘R révéler", revealed ? warn : dim)

        hintLabel.attributedStringValue = attr
    }

    private func moveSecretSelection(by delta: Int) {
        guard !filteredSecrets.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filteredSecrets.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Cmd+R: one key, one idea — show the values instead of dots/masks,
    /// everywhere at once (the field being typed into AND every row
    /// below). See valueFieldPlain's doc comment for why a second field
    /// exists instead of reconfiguring valueField in place. A hard swap,
    /// not a cross-fade — see this file's report for why.
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
        updateHint()
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

        // Only clear the clipboard when it still holds what we captured —
        // on the FIRST successful store of a paste, since the remaining
        // candidates below already live in `candidates`/`candidateIndex`
        // and are never re-read from the pasteboard.
        if let captured = capturedClipboard,
           NSPasteboard.general.string(forType: .string) == captured {
            NSPasteboard.general.clearContents()
        }

        let hasMoreCandidates = candidateIndex + 1 < candidates.count
        guard hasMoreCandidates else {
            close()
            return
        }

        // More keys were extracted from the same paste — walk to the next
        // one exactly as Tab does. candidates/candidateIndex are NOT
        // reset: they are the whole reason this branch exists. Refresh the
        // list so the key just stored is visible while the next one is
        // entered. One gesture per key (Enter, Enter, ...); the panel only
        // closes once nothing is left.
        candidateIndex += 1
        applyCandidate()
        scanGeneration += 1
        refreshSecrets(generation: scanGeneration)
    }
}

// NSSearchField's delegate type is NSSearchFieldDelegate, which is a
// sub-protocol of NSTextFieldDelegate — conformance to the latter alone
// does not satisfy `searchField.delegate`'s type without this explicit
// (empty) declaration.
extension SecretsPanel: NSSearchFieldDelegate {}

extension SecretsPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field === searchField {
            applyFilter()
            relayout(recenter: false)
            return
        }

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
    func numberOfRows(in tableView: NSTableView) -> Int { filteredSecrets.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredSecrets.indices.contains(row) else { return nil }
        let secret = filteredSecrets[row]
        let cell: SecretRowCellView
        if let reused = tableView.makeView(withIdentifier: Self.rowCellID, owner: self) as? SecretRowCellView {
            cell = reused
        } else {
            cell = SecretRowCellView()
            cell.identifier = Self.rowCellID
        }
        let displayValue = revealed ? secret.value : SecretExtractor.maskedValue(secret.value)
        cell.configure(name: secret.name, displayValue: displayValue, length: "\(secret.value.count) car.")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SecretRowBackground()
    }
}
