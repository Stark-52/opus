// PromptPalettePanel — Cmd+Shift+P palette. Lists every prompt the user has
// ever typed into Claude Code on this machine (any project, any session —
// via PromptHistory.load), fuzzy-filters by text/project, and on Return
// INSERTS the picked prompt into the active pane WITHOUT submitting it —
// the user reviews and hits Return themselves, same feel as a paste.
//
// Structural copy of SessionSwitcherPanel (Cmd+K) — same panel mechanics
// (forced .darkAqua, opaque OpusTheme.panelBackground, window-scoped local
// keyDown monitor for Return/Escape/↑/↓, NSTableView with a custom
// selection-row background), sized 620×420 instead of 480×400 since a
// prompt's text needs more room to read than a session title.

import AppKit
import OpusSecretsKit

/// NSPanel returns false for canBecomeKey by default; override so the search
/// field can take keyboard focus when the palette opens. Same technique as
/// SessionSwitcherWindow.
private final class PromptPaletteWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Selected-row background — identical treatment to SessionSwitcherPanel's
/// SessionRowBackground (translucent brand cyan fill + 2pt left accent
/// stripe), so the two palettes read as the same app feature.
private final class PromptRowBackground: NSTableRowView {
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

/// Two-line cell: the prompt text on top, "<folder> · <age>" below in a
/// dimmer color — same layout/alpha convention as SessionSwitcherPanel's
/// SessionCellView.
private final class PromptCellView: NSTableCellView {
    private let promptLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        promptLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        promptLabel.textColor = OpusTheme.cream(0.95)
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.isSelectable = false
        promptLabel.refusesFirstResponder = true

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        subtitleLabel.textColor = OpusTheme.cream(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isSelectable = false
        subtitleLabel.refusesFirstResponder = true

        addSubview(promptLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            promptLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            promptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            promptLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            subtitleLabel.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(prompt: String, subtitle: String) {
        promptLabel.stringValue = prompt
        subtitleLabel.stringValue = subtitle
    }
}

final class PromptPalettePanel: NSObject {
    static let shared = PromptPalettePanel()

    private static let historyURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/history.jsonl")
    private static let cellID = NSUserInterfaceItemIdentifier("PromptCell")

    private let panel: PromptPaletteWindow
    private let searchField: NSSearchField
    private let tableView: NSTableView

    private var allEntries: [PromptEntry] = []
    private var filtered: [PromptEntry] = []
    private var visible = false
    /// Bumped on every open() — a background load whose generation is stale
    /// by the time it returns (palette closed/reopened meanwhile) is
    /// dropped. Same pattern as SessionSwitcherPanel.scanGeneration.
    private var scanGeneration = 0
    /// Retained local keyDown monitor token — AppKit drops an unretained
    /// one. Same caveat as SessionSwitcherPanel.keyMonitor /
    /// TerminalContainerView.commandClickMonitor.
    private var keyMonitor: Any?
    /// Whatever held key status when the palette opened (normally the Quick
    /// Terminal panel) — restored on close so that surface is immediately
    /// typable again. Necessary now that the panel no longer autohides when
    /// an Opus window takes key (see QuickTerminalPanel.panelDidResignKey):
    /// without handing key back, the panel would sit there visible but
    /// keyless and the next keystrokes would go to the frontmost
    /// application instead of Claude.
    private weak var previousKeyWindow: NSWindow?

    private override init() {
        let width: CGFloat = 620
        let height: CGFloat = 420

        panel = PromptPaletteWindow(
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
        // Force dark regardless of system appearance — same rationale as
        // SessionSwitcherPanel: every label here is a light cream color,
        // unreadable if the vibrancy material tints itself light on a
        // light desktop.
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

        // Opaque dark layer on top of the vibrancy blur — same as
        // SessionSwitcherPanel: a HUD-material NSVisualEffectView is still
        // translucent enough for a light desktop to bleed through and wash
        // out the cream text without this.
        let opaqueBG = NSView(frame: blur.bounds)
        opaqueBG.wantsLayer = true
        opaqueBG.layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        opaqueBG.layer?.cornerRadius = OpusTheme.radiusPanel
        opaqueBG.layer?.masksToBounds = true
        opaqueBG.autoresizingMask = [.width, .height]
        blur.addSubview(opaqueBG)

        let field = NSSearchField(frame: NSRect(x: OpusTheme.insetPanel, y: height - 42, width: width - 28, height: 28))
        field.autoresizingMask = [.width, .minYMargin]
        field.placeholderAttributedString = NSAttributedString(
            string: "Search your prompts…",
            attributes: [.foregroundColor: OpusTheme.cream(0.45)]
        )
        field.toolTip = "Inserts the prompt without submitting it."
        field.font = NSFont.systemFont(ofSize: 14)
        field.textColor = OpusTheme.cream(0.95)
        // Same field styling as FindBarView (own drawn background, no
        // system bezel) so this survives Light mode the same way — see
        // OpusTheme.fieldBackground's doc comment for the full story.
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = OpusTheme.fieldBackground
        blur.addSubview(field)
        searchField = field

        let table = NSTableView(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = width - 28 - 16
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.rowHeight = 38
        table.intercellSpacing = NSSize(width: 0, height: 2)
        // `.regular` restores normal AppKit click-to-select for a
        // view-based table — see SessionSwitcherPanel's Fix 1 (v1.4.2) doc
        // comment for why `.none` silently breaks that. PromptRowBackground
        // fully owns the selected-row appearance regardless of this
        // setting (never calls super.drawSelection), so this doesn't bring
        // back AppKit's own blue highlight box either.
        table.selectionHighlightStyle = .regular
        table.style = .plain

        let scroll = NSScrollView(frame: NSRect(x: OpusTheme.insetPanel, y: OpusTheme.insetPanel, width: width - 28, height: height - 42 - 14 - 8))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        blur.addSubview(scroll)
        tableView = table

        super.init()

        field.delegate = self
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)

        // Window-scoped local keyDown monitor for Return/Escape/Up/Down,
        // independent of whichever subview (search field or table) holds
        // first responder — same mechanic, and same rationale, as
        // SessionSwitcherPanel's own keyMonitor (see its install site for
        // the full explanation of why a plain NSTableView can't be relied
        // on to map Return to anything on its own). Every other key returns
        // the event UNTOUCHED so typing still reaches the search field.
        // Never removed — this is a singleton panel that lives for the
        // app's lifetime.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.panel else { return ev }
            switch ev.keyCode {
            case 36:    // Return
                self.openSelection()
                return nil
            case 53:    // Escape
                self.close()
                return nil
            case 125:   // Down arrow
                self.moveSelection(by: 1)
                return nil
            case 126:   // Up arrow
                self.moveSelection(by: -1)
                return nil
            default:
                return ev
            }
        }
    }

    // MARK: Show/hide

    func toggle() {
        visible ? close() : open()
    }

    private func open() {
        scanGeneration += 1
        let generation = scanGeneration

        let screen = activeScreen().frame
        let w = panel.frame.width, h = panel.frame.height
        let origin = NSPoint(x: screen.midX - w / 2, y: screen.midY - h / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: false)

        searchField.stringValue = ""
        allEntries = []
        filtered = []
        tableView.reloadData()

        previousKeyWindow = NSApp.keyWindow
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
        visible = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Built here, on the background queue that already exists for
            // the history read, so the Keychain round-trip never blocks the
            // panel appearing. Values are read once per open, not per
            // keystroke.
            let store = KeychainSecretStore()
            let pairs: [(name: String, value: String)] = ((try? store.names()) ?? []).compactMap { name in
                guard let value = try? store.value(for: name) else { return nil }
                return (name: name, value: value)
            }
            let entries = PromptHistory.load(url: Self.historyURL, redactor: SecretRedactor(secrets: pairs))
            DispatchQueue.main.async {
                guard let self, self.visible, self.scanGeneration == generation else { return }
                self.allEntries = entries
                self.applyFilter()
            }
        }
    }

    private func close() {
        visible = false
        panel.orderOut(nil)
        // Hand key status back explicitly — ordering a non-activating panel
        // out does not do it on its own while Opus is a background app.
        // `openSelection` depends on this: it resolves its insertion target
        // right after calling close(), and the panel being key is what makes
        // that resolution take its first branch.
        if let previous = previousKeyWindow, previous.isVisible { previous.makeKey() }
        previousKeyWindow = nil
    }

    // The "mouse" screen — same rationale/technique as SessionSwitcherPanel/
    // QuickTerminalPanel's activeScreen(): open on whichever monitor the
    // user is currently on, not wherever NSScreen.main happens to be.
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // MARK: Filtering

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [PromptEntry]
        if query.isEmpty {
            base = allEntries
        } else {
            let tokens = query.lowercased().split(separator: " ").map(String.init)
            base = allEntries.filter { e in
                let haystack = (e.text + " " + e.project).lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }
        }
        // Current-project prompts first, then everything else. `base` is
        // already newest-first (PromptHistory.load's own ordering), and a
        // plain two-pass filter preserves that relative order within each
        // half without needing to lean on Swift's sort stability — so this
        // is a partition, not a sort.
        let cwd = OpusPreferences.shared.workingDirectory
        let matching = base.filter { $0.project == cwd }
        let rest = base.filter { $0.project != cwd }
        filtered = matching + rest

        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: Open selection

    @objc private func rowDoubleClicked() {
        openSelection()
    }

    /// Return/double-click: close the palette (which hands key status back to
    /// whatever had it, normally the Quick Terminal panel), then insert the
    /// picked prompt's FULL text — not the truncated display string — into
    /// whichever Claude surface the user is looking at.
    ///
    /// Fix round: this used to call `AppDelegate.activeRestartContainer()`
    /// itself and `return` silently when it resolved nil — which is what
    /// happened on EVERY pick under `.panelOnly`, because opening the palette
    /// stole key status from the panel and the panel autohid itself, leaving
    /// no visible surface for any branch of that resolution to find. The pick
    /// then vanished with no feedback at all. `insertIntoActiveClaude` is the
    /// shared resolve-and-insert path (same one Cmd+Ctrl+S uses) and falls
    /// back to a hidden surface, revealing it, instead of dropping the text.
    private func openSelection() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let entry = filtered[row]
        close()
        AppDelegate.shared?.insertIntoActiveClaude(entry.text)
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: Display formatting

    /// Row display text: newlines shown as "⏎" so a multi-line (typed or
    /// pasted) prompt still reads as one line in the list, then capped at
    /// 100 characters. Display-only — `openSelection` above inserts
    /// `entry.text` untouched, real newlines and all; only what's SHOWN in
    /// the list is truncated/flattened. NSTextField's own
    /// `.byTruncatingTail` still applies on top of this for whatever
    /// doesn't fit even inside those 100 characters at the row's actual
    /// width.
    private static func displayPrompt(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: "⏎")
        return collapsed.count > 100 ? String(collapsed.prefix(100)) : collapsed
    }
}

// MARK: - NSSearchFieldDelegate (live filter)

extension PromptPalettePanel: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension PromptPalettePanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let entry = filtered[row]
        let cell: PromptCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? PromptCellView {
            cell = reused
        } else {
            cell = PromptCellView()
            cell.identifier = Self.cellID
        }
        let folder = entry.project.isEmpty ? "no project" : (entry.project as NSString).lastPathComponent
        let relative = SessionIndex.relativeAge(from: entry.timestamp)
        cell.configure(prompt: Self.displayPrompt(entry.text), subtitle: "\(folder) · \(relative)")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PromptRowBackground()
    }
}
