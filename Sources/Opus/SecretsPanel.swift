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
// below it shows only SecretExtractor.maskedValue output. Cmd+R (or a
// row's eye button — see HoverIconButton) reveals exactly one thing at a
// time — the selected row, or the deposit field when nothing is selected
// — never the whole list at once; see toggleReveal() for how the two stay
// mutually exclusive and tableViewSelectionDidChange() for how a revealed
// row is hidden the moment selection moves elsewhere.
//
// The list exists because depositing blind, with several keys already
// stored, invites near-duplicates ("stripe-key" vs "stripe-live") that are
// only noticed later. It lives at the bottom of THIS panel rather than a
// second one so it is visible at the exact moment it matters: while typing
// the new name. Up/Down browse it without stealing focus from the name
// field (see moveSecretSelection).
//
// Every keyboard shortcut here (Cmd+R, Cmd+Delete, Cmd+F, arrows) has a
// clickable equivalent — this is a graphical panel, not a keyboard-only
// one, and a control the user cannot see is a control they don't know
// exists. The shortcuts stay as the SECOND way to do each thing.
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

/// A borderless, template-image icon button: every clickable control this
/// panel adds (a row's eye and trash, the deposit field's eye) is one of
/// these, so they share one look, one hit-target size, and — more
/// importantly — three behaviours that are easy to get wrong on a
/// non-activating panel:
///
///  - `refusesFirstResponder = true`: the whole panel's design keeps focus
///    in the name field so the user can keep typing while browsing or
///    clicking. A button that could take first responder would break that
///    the instant it's clicked.
///  - `acceptsFirstMouse(for:)` returns true: NSPanel is non-activating,
///    but the FIRST click into it while some other app is frontmost is
///    still normally swallowed as an activation click. Without this
///    override, the user's first click does nothing and only a second
///    click on the same button fires the action — dangerous for the trash
///    button specifically, since "nothing happened, click again" is
///    exactly the gesture that arms a delete.
///  - hover brightening: a resting tint that brightens on mouseEntered,
///    via an NSTrackingArea, so a control that's meant to be always
///    visible (not hover-only — see this file's header) still gives some
///    feedback that it's interactive.
private final class HoverIconButton: NSButton {
    var restingTint: NSColor = OpusTheme.cream(0.55) {
        didSet {
            hoverTint = restingTint.blended(withFraction: 0.35, of: .white) ?? restingTint
            updateTint()
        }
    }
    private var hoverTint: NSColor = OpusTheme.cream(0.9)
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        imagePosition = .imageOnly
        setButtonType(.momentaryChange)
        refusesFirstResponder = true
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        updateTint()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateTint()
    }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateTint()
    }

    private func updateTint() {
        contentTintColor = isHovering ? hoverTint : restingTint
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Builds one HoverIconButton at the shared 20×20 hit target, sized and
/// tinted, with no target/action yet — callers wire those once `self`
/// exists (SecretRowCellView needs its buttons before `self` is valid;
/// SecretsPanel wires row buttons once per reused cell, not per row — see
/// tableView(_:viewFor:)).
private func makeIconButton(symbolName: String, tint: NSColor, accessibilityLabel: String, toolTip: String) -> HoverIconButton {
    let button = HoverIconButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
    image?.isTemplate = true
    button.image = image
    button.restingTint = tint
    button.setAccessibilityLabel(accessibilityLabel)
    button.toolTip = toolTip
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 20),
        button.heightAnchor.constraint(equalToConstant: 20),
    ])
    return button
}

/// Three left-aligned columns — name (fixed width), the masked-or-revealed
/// value in a monospaced font, its length — followed by two always-visible
/// buttons (eye, trash) pinned to the row's trailing edge. Value and
/// length are pinned tight to each other (8pt gap, neither stretches) so
/// the eye can connect "8X…p9" to "10 car." without crossing the row.
/// Both buttons are a FIXED 20×20 regardless of content — if space is
/// tight, it is the value column (see valueColumnWidth's clamp in
/// SecretsPanel.measuredValueColumnWidth) that shrinks, never the
/// controls. The name column's width is likewise a hard NSLayoutConstraint
/// (not intrinsic sizing), so a long value truncates inside its own lane
/// and can never borrow space from — or squeeze — the name column, the one
/// thing here that must stay readable.
private final class SecretRowCellView: NSTableCellView {
    static let nameColumnWidth: CGFloat = 150
    static let lengthColumnWidth: CGFloat = 55
    /// Only used until the first configure() call supplies a real,
    /// content-measured width.
    static let defaultValueColumnWidth: CGFloat = 80

    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let lengthLabel = NSTextField(labelWithString: "")
    private var valueWidthConstraint: NSLayoutConstraint!
    let eyeButton: HoverIconButton
    let copyButton: HoverIconButton
    let trashButton: HoverIconButton

    override init(frame frameRect: NSRect) {
        eyeButton = makeIconButton(symbolName: "eye", tint: OpusTheme.cream(0.55),
                                    accessibilityLabel: "révéler la valeur", toolTip: "Révéler (⌘R)")
        // Revealing shows the value in a fixed-width column, so a long key
        // is read truncated. Copying is the way to get the whole thing out
        // without widening the row or growing its height.
        copyButton = makeIconButton(symbolName: "doc.on.doc", tint: OpusTheme.cream(0.55),
                                     accessibilityLabel: "copier la valeur", toolTip: "Copier la valeur")
        trashButton = makeIconButton(symbolName: "trash", tint: OpusTheme.red,
                                      accessibilityLabel: "supprimer ce secret", toolTip: "Supprimer (⌘⌫)")
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
        addSubview(eyeButton)
        addSubview(copyButton)
        addSubview(trashButton)

        let valueWidth = valueLabel.widthAnchor.constraint(equalToConstant: Self.defaultValueColumnWidth)
        valueWidthConstraint = valueWidth

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.nameColumnWidth),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            valueLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            valueWidth,
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // No trailing constraint on length: a width here, right after
            // the value with nothing pulling it wider, is what keeps this
            // column from being distributed across the row — the leftover
            // space falls after it, unused. A defensive `<=` against the
            // eye button's leading edge costs nothing when the value
            // column's own clamp already leaves room (it does — see
            // measuredValueColumnWidth), and turns any future budget
            // mistake into a visible Auto Layout conflict instead of a
            // silent overlap.
            lengthLabel.leadingAnchor.constraint(equalTo: valueLabel.trailingAnchor, constant: 8),
            lengthLabel.widthAnchor.constraint(equalToConstant: Self.lengthColumnWidth),
            lengthLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            lengthLabel.trailingAnchor.constraint(lessThanOrEqualTo: eyeButton.leadingAnchor, constant: -6),

            // Ordered look, take, destroy — with the destructive one
            // furthest from where the eye lands first.
            trashButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trashButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: trashButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            eyeButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            eyeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(name: String, displayValue: String, length: String, valueColumnWidth: CGFloat,
                    revealed: Bool, deleteArmed: Bool) {
        nameLabel.stringValue = name
        valueLabel.stringValue = displayValue
        // The revealed row borrows its own length column: a masked preview
        // is six characters and a real key is fifty, so the shared column
        // width that keeps every OTHER row from moving would show a useless
        // prefix here. Taking the space per-row means the extra width costs
        // no movement anywhere else in the list, and the length is the one
        // thing already legible from the value now that it is in plain
        // sight. Everything is restored on the next configure(), which cell
        // reuse guarantees runs before this view represents another row.
        lengthLabel.stringValue = revealed ? "" : length
        valueWidthConstraint.constant = revealed
            ? valueColumnWidth + Self.lengthColumnWidth + 8
            : valueColumnWidth

        let eyeSymbol = revealed ? "eye.slash" : "eye"
        let eyeLabel = revealed ? "masquer la valeur" : "révéler la valeur"
        let eyeImage = NSImage(systemSymbolName: eyeSymbol, accessibilityDescription: eyeLabel)
        eyeImage?.isTemplate = true
        eyeButton.image = eyeImage
        eyeButton.setAccessibilityLabel(eyeLabel)
        eyeButton.toolTip = revealed ? "Masquer (⌘R)" : "Révéler (⌘R)"

        let trashSymbol = deleteArmed ? "trash.fill" : "trash"
        let trashImage = NSImage(systemSymbolName: trashSymbol, accessibilityDescription: "supprimer ce secret")
        trashImage?.isTemplate = true
        trashButton.image = trashImage
        trashButton.toolTip = deleteArmed ? "Confirmer la suppression (⌘⌫)" : "Supprimer (⌘⌫)"
    }
}

final class SecretsPanel: NSObject {
    static let shared = SecretsPanel()

    private static let rowCellID = NSUserInterfaceItemIdentifier("SecretRow")
    /// Width never changes — only height, via relayout(), as the filtered
    /// list grows or shrinks.
    private static let width: CGFloat = 520
    private static let topMargin: CGFloat = 24
    /// keyCode 51 is Delete (labelled "Delete" on a Mac keyboard, and what
    /// most apps call Backspace) — the physical key Cmd+Delete pairs with.
    private static let deleteKeyCode: UInt16 = 51

    private let panel: SecretsPanelWindow
    /// Set only while reloadTableContent() re-applies the selection a
    /// reloadData() just cleared, so tableViewSelectionDidChange can tell
    /// that bookkeeping apart from the user actually moving off a row.
    private var isRestoringSelection = false
    /// Dismisses the panel when it stops being the key window — see where
    /// it is registered for why it must not restore focus.
    private var resignObserver: NSObjectProtocol?
    /// Complements resignObserver for the one case it cannot see: a click
    /// on Opus's own terminal window, which never takes key from the panel.
    private var clickAwayMonitor: Any?
    private let titleLabel = NSTextField(labelWithString: "Ranger un secret")
    private let nameField = NSTextField()
    private let valueField = NSSecureTextField()
    /// Stacked in the exact same frame as valueField, hidden unless Cmd+R
    /// (or its own eye button) is on. NSSecureTextField cannot be switched
    /// to plain text in place, so this is the usual AppKit workaround: two
    /// fields, one frame, only one ever visible. Kept mirrored with
    /// valueField on every keystroke (see controlTextDidChange) so
    /// toggling never drops or duplicates what's been typed, and both are
    /// wiped on close() regardless of which was showing.
    private let valueFieldPlain = NSTextField()
    /// Unlike a row's eye (which lives inside SecretRowCellView, built
    /// fresh per cell), this one is a permanent fixture of the panel
    /// itself, positioned in relayout() at the trailing edge of the value
    /// field's own row — narrower than the panel's other full-width rows
    /// to make room for it.
    private let depositEyeButton = makeIconButton(symbolName: "eye", tint: OpusTheme.cream(0.55),
                                                   accessibilityLabel: "révéler la valeur", toolTip: "Révéler (⌘R)")
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
    /// State-aware, not a static legend: reflects exactly what's currently
    /// clickable/exposed, not a fixed set of instructions — see
    /// updateHint().
    private let hintLabel = NSTextField(labelWithString: "")

    private let store = KeychainSecretStore()
    private var visible = false
    /// Bumped on every open() AND on every successful commit()/delete that
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
    /// table and what Up/Down browse, and the one array row-identity
    /// resolution (a click, an arrow move) is ever allowed to index into.
    private var filteredSecrets: [SecretRow] = []
    /// Set by the most recent renderSecrets(); overrides the count in
    /// listHeaderLabel with the problem text, in red, until a read
    /// succeeds cleanly again.
    private var storeProblem: String?
    /// Reveal shows ONE thing at a time — the deposit field, or a single
    /// selected row — never both, and never the whole list at once: six
    /// values on screen because the user wanted to check one is exactly
    /// the exposure this is meant to avoid. Both reset on open()/close();
    /// see toggleReveal() for how they stay mutually exclusive and
    /// tableViewSelectionDidChange() for how a revealed row is hidden the
    /// moment selection moves elsewhere.
    private var revealedValueField = false
    private var revealedRowName: String?
    /// Armed by a first Cmd+Delete or trash-button click on this name; a
    /// second, matching one deletes. Mirrors pendingOverwrite's own
    /// two-step pattern above. Cleared by ANY other interaction —
    /// cancelPendingDelete() is the one place that happens, called from
    /// the keyDown monitor's general "any other key" rule and from every
    /// mouse action that doesn't itself confirm this exact name.
    private var pendingDeleteName: String?
    /// Set right before a delete's refreshSecrets() call; consumed once by
    /// the renderSecrets() that follows to select whatever row now sits at
    /// the deleted one's old index (or clear selection if the list is now
    /// empty), rather than leaving the selection pointing at an index that
    /// no longer exists, or forcing a selection after every OTHER kind of
    /// refresh (a deposit, a filter) where nothing asked for one.
    private var pendingSelectionIndex: Int?
    /// The list's value column width, recomputed by
    /// measuredValueColumnWidth() alongside every reloadTableContent()
    /// call — sized to the widest value actually displayed right now
    /// (masked text for every row except one revealed row, if any) rather
    /// than a fixed guess, so short values don't leave the length column
    /// stranded far to their right.
    private var valueColumnWidth: CGFloat = SecretRowCellView.defaultValueColumnWidth
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

        depositEyeButton.target = self
        depositEyeButton.action = #selector(depositEyeButtonClicked(_:))
        blur.addSubview(depositEyeButton)

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

        // NSSecureTextField advertises itself as a password field, so macOS
        // Password AutoFill attaches to it and injects its own "Passwords…"
        // button INTO the panel: it landed on top of the filter row, hiding
        // it, and took the keyboard focus ring on open. Clearing contentType
        // withdraws that advertisement. The field still masks its text and
        // still refuses to be read by other apps; we simply stop asking the
        // system to offer saved passwords for a field that holds API keys.
        valueField.contentType = nil

        nameField.delegate = self
        valueField.delegate = self
        valueFieldPlain.delegate = self
        searchField.delegate = self
        tableView.delegate = self
        tableView.dataSource = self

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.panel else { return ev }

            // Cmd+Delete is handled before the general "any other key
            // cancels a pending delete" rule below, since CONFIRMING a
            // pending delete is itself a second Cmd+Delete. With no row
            // selected this returns false and the event passes through
            // unconsumed, so Cmd+Delete keeps its normal text-editing
            // meaning in whichever field has focus — same as before this
            // feature existed; it is never given a new meaning there.
            if KeyMods.shortcutMods(ev.modifierFlags) == .command, ev.keyCode == Self.deleteKeyCode {
                return self.handleDeleteKeyboardShortcut() ? nil : ev
            }

            // Any OTHER key cancels a pending delete confirmation —
            // typing a name, moving the selection, opening the filter,
            // Escape, all of it. A confirmation that survives the user
            // moving on to something else is how accidents happen. This is
            // a top-level call (not reentrant with any table machinery),
            // so reloading immediately — to un-arm the row's trash icon —
            // is safe here, unlike inside tableViewSelectionDidChange.
            // (Mouse-driven cancellation — a click on a different row's
            // button — is handled separately, in cancelPendingDelete()'s
            // other call sites, since this monitor only ever sees keys.)
            if self.cancelPendingDelete() {
                self.reloadTableContent()
            }

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

        // Click anywhere outside and the panel goes away, like every other
        // transient panel on the system. Without this it floated above
        // everything until Escape — a window full of secret names parked on
        // top of whatever the user moved on to.
        //
        // restoringFocus: false is the whole point on this path. close()
        // normally hands focus back to the window that had it before the
        // panel opened; doing that here would rip focus away from whatever
        // the user just clicked, which is the opposite of what dismissing
        // by clicking elsewhere means.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.visible else { return }
            self.close(restoringFocus: false)
        }

        // The notification above only fires when the panel actually loses
        // key status, which covers switching apps but NOT clicking Opus's
        // own terminal window behind it: that window does not take key from
        // the panel, so the panel just sat there on top. Watching the click
        // itself catches both, and catches the terminal case at the moment
        // the user expects.
        //
        // The event is passed through untouched: the click the user made is
        // theirs, not a dismiss gesture to be swallowed. Dismissing on the
        // click AND letting it land is the behaviour of every menu-like
        // panel that does this well.
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] ev in
            guard let self, self.visible, ev.window !== self.panel else { return ev }
            self.close(restoringFocus: false)
            return ev
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
        // Both gaps framing statusLabel are the same tight 6pt (was 6/12)
        // — the reserved 18pt HEIGHT is untouched, it must never move
        // between an empty and a populated status line, but the extra
        // padding that made an EMPTY status line read as a hole between
        // the preview line and the separator is gone.
        stack(statusLabel, height: 18, gapAfter: 6)
        stack(separator, height: 1, gapAfter: 12)
        stack(searchField, height: 26, gapAfter: 8)
        stack(listHeaderLabel, height: 20, gapAfter: 8)
        stack(scrollView, height: listHeight, gapAfter: 8)
        stack(hintLabel, height: 18, gapAfter: 0)

        let newHeight = distanceFromTop + inset

        for (view, y0, height) in stacked {
            view.frame = NSRect(x: inset, y: newHeight - y0 - height, width: fieldWidth, height: height)
        }

        // The value field's row is narrower than the panel's other
        // full-width rows, to leave room for its own eye button pinned to
        // the trailing edge — same "fixed control, shrinking field" idea
        // as the list rows, just with one field instead of a value column.
        let depositEyeSize: CGFloat = 20
        let depositFieldWidth = fieldWidth - depositEyeSize - 8
        let valueFrame = valueField.frame
        valueField.frame = NSRect(x: inset, y: valueFrame.origin.y, width: depositFieldWidth, height: valueFrame.height)
        valueFieldPlain.frame = valueField.frame
        depositEyeButton.frame = NSRect(
            x: inset + depositFieldWidth + 8,
            y: valueFrame.origin.y + (valueFrame.height - depositEyeSize) / 2,
            width: depositEyeSize, height: depositEyeSize
        )

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
        pendingDeleteName = nil
        candidateIndex = 0

        // Reveal always starts OFF, regardless of how it was left before —
        // close() already resets this, but a fresh open() asserts it too
        // rather than trusting that every path into "not visible" went
        // through close().
        revealedValueField = false
        revealedRowName = nil
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        updateDepositEyeButton()
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
        // Always the name field, which is the panel's first row and the
        // first thing a reader's eye lands on. This used to focus the value
        // field whenever the clipboard yielded no candidate, on the theory
        // that an empty value is the thing to fill first — but on screen
        // that meant opening the panel and typing a name put the name into
        // the VALUE field, masked, with the name field still showing its
        // placeholder. Costing a Tab in the no-clipboard case is far
        // cheaper than silently storing a name as if it were a secret.
        panel.makeFirstResponder(nameField)
        visible = true
    }

    /// restoringFocus is false only when the panel is going away BECAUSE
    /// focus moved somewhere else (see resignObserver); every other caller
    /// wants the window that was key before the panel opened to get it back.
    private func close(restoringFocus: Bool = true) {
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
        pendingDeleteName = nil
        pendingSelectionIndex = nil
        revealedValueField = false
        revealedRowName = nil
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        updateDepositEyeButton()
        rows = []
        filteredSecrets = []
        storeProblem = nil
        searchField.stringValue = ""
        reloadTableContent()

        // Hand focus back FIRST, synchronously, never gated behind the
        // dismiss animation below. The window is free to keep fading on
        // screen for another 90ms; the surface the user is about to type
        // into again must be key the instant this runs, or keystrokes
        // typed right after are lost.
        if restoringFocus, let previous = previousKeyWindow, previous.isVisible { previous.makeKey() }
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
    /// always has. (A pending delete confirmation is cancelled by the
    /// keyDown monitor's general rule before this even runs.)
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
        // Any normal preview recompute reasserts the amber tone — the only
        // other color statusLabel ever takes is OpusTheme.red, for a
        // delete confirmation or a delete/store failure, and those are
        // meant to be transient: the next normal update (this function)
        // clears them back to amber, same as it already clears their TEXT.
        statusLabel.textColor = OpusTheme.amber

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

        // Consumed once: a delete sets this right before calling
        // refreshSecrets() so the row that "took the deleted one's place"
        // (same index, in the fresh list) ends up selected instead of the
        // selection just vanishing or pointing at an index that no longer
        // exists. Every other refresh (a deposit, a filter edit) leaves
        // this nil and therefore leaves selection exactly as it was.
        if let index = pendingSelectionIndex {
            pendingSelectionIndex = nil
            if filteredSecrets.isEmpty {
                tableView.deselectAll(nil)
            } else {
                let clamped = min(index, filteredSecrets.count - 1)
                tableView.selectRowIndexes(IndexSet(integer: clamped), byExtendingSelection: false)
                tableView.scrollRowToVisible(clamped)
            }
        }
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
        // Defensive companion to tableViewSelectionDidChange: if the
        // revealed row filtered out of view (or vanished from a fresh
        // Keychain read) rather than simply losing selection, don't keep
        // calling it "revealed" for a row that isn't shown anywhere.
        if let revealedRowName, !filteredSecrets.contains(where: { $0.name == revealedRowName }) {
            self.revealedRowName = nil
        }
        // Same idea for a pending delete confirmation on a row that just
        // filtered out of view.
        if let pendingDeleteName, !filteredSecrets.contains(where: { $0.name == pendingDeleteName }) {
            self.pendingDeleteName = nil
        }
        reloadTableContent()
        updateListHeader(filterActive: !query.isEmpty)
        updateHint()
    }

    /// Whatever is left of the row once every fixed part has taken its
    /// share. Constant, deliberately: it used to be measured from the text
    /// on screen, which meant revealing a row widened the column and shoved
    /// the length text and all three buttons sideways on EVERY row — the
    /// panel lurching at each click. Content-fitting also left the row's
    /// whole right-hand third empty, since masked previews are six
    /// characters wide, while the revealed value that actually needed room
    /// was the one being truncated.
    ///
    /// Filling the row instead gives the value the largest column the panel
    /// can offer, and gives it unconditionally, so nothing here depends on
    /// what is displayed and nothing moves when that changes. A revealed
    /// value longer than this still truncates; the copy button is how the
    /// whole value is read.
    private func measuredValueColumnWidth() -> CGFloat {
        // Every fixed horizontal cost in SecretRowCellView's constraints,
        // in row order: leading inset, name column, gap, [value], gap,
        // length column, gap, eye, gap, copy, gap, trash, trailing inset.
        let fixed: CGFloat = 6 + SecretRowCellView.nameColumnWidth + 10
            + 8 + SecretRowCellView.lengthColumnWidth + 6
            + 20 + 4 + 20 + 4 + 20 + 8
        let rowWidth = Self.width - OpusTheme.insetPanel * 2
        // The floor matters only if the panel is ever narrowed: a negative
        // or tiny width would collapse the column rather than scroll it.
        return max(rowWidth - fixed, 60)
    }

    /// Recomputes the value column's width from what's about to be
    /// displayed, THEN reloads. Every reloadData() that can change what's
    /// shown in the value column (a filter, a reveal toggle, a fresh
    /// Keychain read, closing) goes through this instead of calling
    /// tableView.reloadData() directly, so the column never lags a frame
    /// behind the content it's sized to.
    private func reloadTableContent() {
        // reloadData() drops the table's selection here, and everything in
        // this panel that acts on "the current row" reads
        // tableView.selectedRow: Cmd+Delete's guard, toggleReveal's choice
        // between a row and the deposit field, the hint line's "⌘⌫
        // supprimer" segment. Losing it silently is what made the panel
        // unusable on screen — arming a delete reloaded, the reload cleared
        // the selection, and the confirming Cmd+Delete then found nothing
        // to confirm while a second trash click re-armed forever.
        //
        // Selection is preserved by NAME, not by index: a reload can follow
        // a filter change or a delete, after which the old index points at
        // a different secret (or past the end), and re-selecting an index
        // blindly would silently move the user onto a row they never chose
        // — with a delete possibly armed.
        let keptName = filteredSecrets.indices.contains(tableView.selectedRow)
            ? filteredSecrets[tableView.selectedRow].name
            : nil

        valueColumnWidth = measuredValueColumnWidth()
        tableView.reloadData()

        guard let keptName, let row = filteredSecrets.firstIndex(where: { $0.name == keptName }) else { return }
        // Restoring is bookkeeping, not a user action: suppress the
        // delegate so it doesn't read this as "the user moved off the row"
        // and cancel a pending delete or mask a revealed value.
        isRestoringSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
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

    /// State-aware, not a static legend. "↑↓ parcourir" and "⌘⌫ supprimer"
    /// are only advertised when there's a row to act on (matching
    /// moveSecretSelection's and handleDeleteKeyboardShortcut's own
    /// guards); "⌘R révéler"/"⌘R masquer" swap text AND color depending on
    /// whether ANYTHING is currently exposed — the deposit field or a row,
    /// never both — so this stays accurate about what's on screen and
    /// clickable right now rather than describing a fixed "mode."
    private func updateHint() {
        let font = NSFont.systemFont(ofSize: 11)
        let dim: [NSAttributedString.Key: Any] = [.foregroundColor: OpusTheme.cream(0.5), .font: font]
        let warn: [NSAttributedString.Key: Any] = [.foregroundColor: OpusTheme.amber, .font: font]

        let somethingRevealed = revealedValueField || revealedRowName != nil
        let rowSelected = filteredSecrets.indices.contains(tableView.selectedRow)

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
        if rowSelected {
            addSegment("⌘⌫ supprimer", dim)
        }
        addSegment(somethingRevealed ? "⌘R masquer" : "⌘R révéler", somethingRevealed ? warn : dim)

        hintLabel.attributedStringValue = attr
    }

    /// Selection itself never reveals or deletes anything (see
    /// tableViewSelectionDidChange for what DOES follow from it: hiding a
    /// revealed row, cancelling a pending delete) — this just moves the
    /// highlight.
    private func moveSecretSelection(by delta: Int) {
        guard !filteredSecrets.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filteredSecrets.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    /// Cmd+R acts on whatever the panel is currently pointing at, and only
    /// that one thing: the selected row if there is one, otherwise the
    /// deposit field. A row's own eye button goes through
    /// toggleRevealForSelectedRow() too (after first selecting that row —
    /// see rowEyeButtonClicked), so a click and Cmd+R are the exact same
    /// state machine, never two.
    private func toggleReveal() {
        if filteredSecrets.indices.contains(tableView.selectedRow) {
            toggleRevealForSelectedRow()
        } else {
            toggleDepositFieldReveal()
        }
    }

    /// Reveals/masks whichever row is CURRENTLY selected. Revealing a row
    /// masks the deposit field first (maskDepositField()) so the two are
    /// never showing plaintext at the same time.
    private func toggleRevealForSelectedRow() {
        let selectedRow = tableView.selectedRow
        guard filteredSecrets.indices.contains(selectedRow) else { return }
        let name = filteredSecrets[selectedRow].name
        if revealedRowName == name {
            revealedRowName = nil
        } else {
            revealedRowName = name
            maskDepositField()
        }
        reloadTableContent()
        updateHint()
    }

    /// Reveals/masks the deposit field itself. Unlike toggleReveal(), this
    /// is unconditional — the deposit eye button is physically attached to
    /// the field it controls, so there's no "what does the user mean" to
    /// resolve the way Cmd+R has to. Mutual exclusion still applies:
    /// turning this on clears any revealed row.
    private func toggleDepositFieldReveal() {
        revealedRowName = nil
        revealedValueField.toggle()

        let wasEditingSecure = valueField.currentEditor() != nil
        let wasEditingPlain = valueFieldPlain.currentEditor() != nil

        valueField.isHidden = revealedValueField
        valueFieldPlain.isHidden = !revealedValueField

        // If the value field itself had focus, hand it to whichever of the
        // pair is now visible so typing keeps working uninterrupted. If
        // focus was elsewhere (typically nameField), leave it there — this
        // never moves focus on its own.
        if revealedValueField, wasEditingSecure {
            panel.makeFirstResponder(valueFieldPlain)
        } else if !revealedValueField, wasEditingPlain {
            panel.makeFirstResponder(valueField)
        }

        updateDepositEyeButton()
        reloadTableContent()
        updateHint()
    }

    /// Re-masks the deposit field if it's currently revealed, restoring
    /// focus to the secure field if the plain one held it. Called right
    /// before a row reveal turns on, so the deposit field and a row are
    /// never both showing plaintext.
    private func maskDepositField() {
        guard revealedValueField else { return }
        revealedValueField = false
        let wasEditingPlain = valueFieldPlain.currentEditor() != nil
        valueField.isHidden = false
        valueFieldPlain.isHidden = true
        if wasEditingPlain {
            panel.makeFirstResponder(valueField)
        }
        updateDepositEyeButton()
    }

    private func updateDepositEyeButton() {
        let symbol = revealedValueField ? "eye.slash" : "eye"
        let label = revealedValueField ? "masquer la valeur" : "révéler la valeur"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        depositEyeButton.image = image
        depositEyeButton.setAccessibilityLabel(label)
        depositEyeButton.toolTip = revealedValueField ? "Masquer (⌘R)" : "Révéler (⌘R)"
    }

    // MARK: Delete

    /// "Any other interaction cancels the arming" — the one place that
    /// happens. Called from the keyDown monitor's general rule (covers
    /// every key except the confirming Cmd+Delete) and from every mouse
    /// action that doesn't itself confirm this exact name (a row's eye
    /// button, the deposit eye button — a different row's trash button
    /// doesn't need this, since armOrConfirmDelete already replaces
    /// whatever name was pending when it arms a new one).
    ///
    /// Deliberately does NOT reload the table itself: a row's trash icon
    /// needs to revert from its armed look, but a reload called
    /// synchronously from INSIDE tableViewSelectionDidChange is reentrant
    /// with NSTableView's own in-flight selection bookkeeping and was
    /// found to corrupt it (see that method's own comment for the full
    /// story — the same hazard that made revealedRowName's clear-then-
    /// reload deferred). Callers outside that context may reload
    /// immediately; tableViewSelectionDidChange defers. Returns whether
    /// anything was actually cancelled, so callers don't reload for
    /// nothing.
    @discardableResult
    private func cancelPendingDelete() -> Bool {
        guard pendingDeleteName != nil else { return false }
        pendingDeleteName = nil
        updatePreview()
        return true
    }

    /// Cmd+Delete resolves the name from the CURRENT SELECTION — there is
    /// no clicked view to ask, unlike a button press. Returns whether a
    /// row was selected at all: false means "nothing to do," which the
    /// caller passes through to the field editor rather than treating as
    /// anything to do with the panel.
    private func handleDeleteKeyboardShortcut() -> Bool {
        guard filteredSecrets.indices.contains(tableView.selectedRow) else { return false }
        armOrConfirmDelete(name: filteredSecrets[tableView.selectedRow].name)
        return true
    }

    /// The two-step delete itself, shared by Cmd+Delete (resolves the name
    /// from selection) and a row's trash button (resolves it via
    /// tableView.row(for:) — see rowTrashButtonClicked). Mirrors
    /// pendingOverwrite's own confirm-then-act pattern for a store: one
    /// call arms, naming the secret in the status line; the second, on the
    /// SAME name, actually deletes.
    private func armOrConfirmDelete(name: String) {
        guard pendingDeleteName == name else {
            pendingDeleteName = name
            statusLabel.textColor = OpusTheme.red
            statusLabel.stringValue = "supprimer « \(name) » ? ⌘⌫ à nouveau pour confirmer"
            reloadTableContent()   // so the row's own trash button switches to its armed look
            updateHint()
            return
        }

        pendingDeleteName = nil
        do {
            try store.remove(name: name)
        } catch {
            // Same rule as everywhere else in this file: report the real
            // error, in red, rather than silently doing nothing OR
            // refreshing the list as though the delete had worked.
            statusLabel.textColor = OpusTheme.red
            statusLabel.stringValue = "échec de la suppression : \(error)"
            reloadTableContent()
            updateHint()
            return
        }

        if revealedRowName == name { revealedRowName = nil }
        statusLabel.textColor = OpusTheme.amber
        statusLabel.stringValue = ""

        pendingSelectionIndex = filteredSecrets.firstIndex { $0.name == name }
        scanGeneration += 1
        refreshSecrets(generation: scanGeneration)
    }

    /// Pure and file-visible so it's testable without a live table view:
    /// given the row index AppKit resolves for a clicked button
    /// (tableView.row(for:)) and the names of the secrets CURRENTLY
    /// FILTERED into view (in display order), returns the name at that
    /// index, or nil if it's out of range — e.g. a stale click racing a
    /// filter change that shrank the list out from under it. This is the
    /// one seam a click and a keyboard action share for "which secret is
    /// this," so getting it wrong deletes a secret the user didn't point
    /// at. Callers must pass filteredSecrets' names, never rows' (the full,
    /// unfiltered set) — indexing the wrong one is exactly the bug this
    /// exists to catch.
    static func resolveRowName(at index: Int, filteredNames: [String]) -> String? {
        guard filteredNames.indices.contains(index) else { return nil }
        return filteredNames[index]
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

    // MARK: Button actions

    @objc private func depositEyeButtonClicked(_ sender: NSButton) {
        cancelPendingDelete()
        toggleDepositFieldReveal()
    }

    @objc private func rowEyeButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard Self.resolveRowName(at: row, filteredNames: filteredSecrets.map(\.name)) != nil else { return }
        cancelPendingDelete()
        // Clicking a row's eye also selects that row: mouse and keyboard
        // converge on ONE notion of "which row," never two, so a
        // following Cmd+R (or Cmd+Delete) acts on the same row the user
        // just clicked. toggleRevealForSelectedRow() re-resolves the name
        // from that selection, so this method never needs to carry it.
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        toggleRevealForSelectedRow()
    }

    /// Copying is the answer to "the revealed value is truncated": the row
    /// shows as much as its column allows, this puts the whole thing on the
    /// clipboard. Resolves the row at click time like every other row
    /// button, and reads the value from filteredSecrets rather than from the
    /// label, which may be showing the masked form.
    @objc private func rowCopyButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard filteredSecrets.indices.contains(row) else { return }
        cancelPendingDelete()
        let secret = filteredSecrets[row]

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // setString reports failure rather than throwing, and a silent
        // failure here is the worst kind: the user pastes whatever was on
        // the clipboard BEFORE, believing it is their key.
        guard pasteboard.setString(secret.value, forType: .string) else {
            statusLabel.textColor = OpusTheme.red
            statusLabel.stringValue = "copie refusée par le presse-papier"
            return
        }
        statusLabel.textColor = OpusTheme.cream(0.6)
        statusLabel.stringValue = "« \(secret.name) » copiée dans le presse-papier"
        reloadTableContent()
        updateHint()
    }

    @objc private func rowTrashButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard let name = Self.resolveRowName(at: row, filteredNames: filteredSecrets.map(\.name)) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        armOrConfirmDelete(name: name)
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
            // Wired ONCE per cell instance, never per row: both actions
            // resolve the actual row fresh, via tableView.row(for:), at
            // CLICK time — never from anything captured here — so cell
            // reuse across a reload/filter can never fire on a stale row.
            cell.eyeButton.target = self
            cell.eyeButton.action = #selector(rowEyeButtonClicked(_:))
            cell.copyButton.target = self
            cell.copyButton.action = #selector(rowCopyButtonClicked(_:))
            cell.trashButton.target = self
            cell.trashButton.action = #selector(rowTrashButtonClicked(_:))
        }
        let displayValue = secret.name == revealedRowName ? secret.value : SecretExtractor.maskedValue(secret.value)
        cell.configure(name: secret.name, displayValue: displayValue, length: "\(secret.value.count) car.",
                        valueColumnWidth: valueColumnWidth,
                        revealed: secret.name == revealedRowName,
                        deleteArmed: secret.name == pendingDeleteName)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SecretRowBackground()
    }

    /// "Selecting a different row hides the previously revealed one," and
    /// cancels a pending delete confirmation too — the direct
    /// implementation of both rules. Fires for arrow-key navigation
    /// (moveSecretSelection's selectRowIndexes), a click anywhere on a row
    /// (including a button, which also explicitly selects its row — see
    /// rowEyeButtonClicked/rowTrashButtonClicked), so nothing mouse-driven
    /// can leave a revealed row or an armed delete behind once selection
    /// moves away from it.
    func tableViewSelectionDidChange(_ notification: Notification) {
        // reloadTableContent() re-applies the selection it just lost. That
        // is not the user moving, so none of the "you left the row" rules
        // below apply to it.
        guard !isRestoringSelection else { return }

        // Both of these can flip a row's on-screen state (an armed trash
        // icon, a revealed value) without changing anything ELSE about
        // the row content, so both are collapsed into the SAME deferred
        // reload below rather than each scheduling their own — see that
        // reload's own comment for why it can't run synchronously here.
        var needsReload = cancelPendingDelete()

        if let revealedRowName {
            let selected = tableView.selectedRow
            if !filteredSecrets.indices.contains(selected) || filteredSecrets[selected].name != revealedRowName {
                self.revealedRowName = nil
                needsReload = true
            }
        }

        updateHint()

        guard needsReload else { return }
        // Deferred, not synchronous. This delegate method is called BY
        // NSTableView while it is still committing the very selection
        // change it's announcing — reloading the table from inside that
        // call stack is reentrant with AppKit's own in-flight bookkeeping
        // and was found to corrupt it: Up/Down got stuck re-selecting row
        // 0 because a reload fired from here raced a selection change
        // AppKit hadn't finished committing yet. Waiting for the next run
        // loop tick (still before this event's display flush, so nothing
        // stale is visibly shown in the meantime) lets that commit finish
        // first.
        DispatchQueue.main.async { [weak self] in
            self?.reloadTableContent()
        }
    }
}
