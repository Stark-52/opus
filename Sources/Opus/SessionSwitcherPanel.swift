// SessionSwitcherPanel — Cmd+K palette. Lists every Claude Code conversation
// on this machine (any project, any cwd — via SessionIndex.scan), fuzzy-
// filters by title/cwd, and resumes the picked one INTO THE SHARED SESSION
// (tab 0), same mechanism as "Switch Project": set the working directory,
// then ClaudeBackend.restart(mode: .resume(sessionId:)).
//
// This only ever targets the shared session — if the user is currently
// looking at a private tab (Cmd+T), Cmd+K still resumes tab 0 underneath it.
// That mirrors the existing Switch Project menu and is called out in the
// search field's placeholder/tooltip rather than silently surprising anyone.

import AppKit

/// NSPanel returns false for canBecomeKey by default; override so the search
/// field can take keyboard focus when the palette opens. Same technique as
/// OpusPanel in main.swift.
private final class SessionSwitcherWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Selected-row background — same translucent brand cyan as OpusTabBar's
/// active-tab pill, so the palette reads as part of the same app.
///
/// Fix 1 (v1.4.2): this override IS the entire selection-drawing story —
/// it never calls `super.drawSelection(in:)`, so it already fully replaces
/// AppKit's own default highlight box regardless of the table's
/// `selectionHighlightStyle`. That means switching the table from `.none`
/// to `.regular` below (the actual click-to-select fix) introduces no
/// double-draw: there was never a second drawSelection implementation to
/// collide with. Left unchanged from v1.4.1 — no code churn needed here.
private final class SessionRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let r = bounds.insetBy(dx: 4, dy: 1)
        OpusTheme.cyan.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        // 2pt left-edge accent stripe (spec section 5) — a stronger cyan than
        // the fill so the selected row reads at a glance even at a distance.
        let stripe = NSRect(x: r.minX, y: r.minY, width: 2, height: r.height)
        OpusTheme.cyan.withAlphaComponent(0.6).setFill()
        NSBezierPath(rect: stripe).fill()
    }
}

/// Two-line cell: title on top, "folder · branch · relative time" below in
/// a dimmer color — same alpha convention as OpusTabBar's inactive labels.
private final class SessionCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = OpusTheme.cream(0.95)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        // Fix 1 (v1.4.2) defensive: `labelWithString:` already configures
        // isSelectable=false, but a click landing on a label must never be
        // able to grab first responder / start a text-selection drag either
        // — that would compete with the table's own click-to-select. Costs
        // nothing since these are never meant to be interactive.
        titleLabel.isSelectable = false
        titleLabel.refusesFirstResponder = true

        subtitleLabel.font = NSFont.systemFont(ofSize: 11)
        // Harmonization spec section 5: subtitle = cream 55% (was 60%, itself
        // a bump from an even earlier 50% — see the panel-level doc comment
        // on why every label here uses an explicit color instead of an
        // adaptive one).
        subtitleLabel.textColor = OpusTheme.cream(0.55)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.isSelectable = false   // Fix 1 (v1.4.2) defensive — see titleLabel above
        subtitleLabel.refusesFirstResponder = true

        addSubview(titleLabel)
        addSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),

            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(title: String, subtitle: String) {
        titleLabel.stringValue = title
        subtitleLabel.stringValue = subtitle
    }
}

final class SessionSwitcherPanel: NSObject {
    static let shared = SessionSwitcherPanel()

    private static let projectsDir = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects")
    private static let cellID = NSUserInterfaceItemIdentifier("SessionCell")
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private let panel: SessionSwitcherWindow
    private let searchField: NSSearchField
    private let tableView: NSTableView

    private var allSessions: [SessionSummary] = []
    private var filtered: [SessionSummary] = []
    private var visible = false
    /// Bumped on every open() — a background scan whose generation is stale
    /// by the time it returns (palette closed/reopened meanwhile) is dropped.
    private var scanGeneration = 0
    /// v1.4.2 task-review Finding 4 — retained local keyDown monitor token;
    /// see its installation site (end of `init`) for what it does and why.
    /// AppKit drops an unretained monitor, same caveat as
    /// `TerminalContainerView.commandClickMonitor`.
    private var keyMonitor: Any?

    private override init() {
        let width: CGFloat = 480
        let height: CGFloat = 400

        panel = SessionSwitcherWindow(
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
        // Fix 4 (v1.4.1): on a LIGHT desktop, the vibrancy blur below tinted
        // itself light too, and every label in this panel is a light cream
        // color — unreadable. Force dark regardless of the system appearance
        // so the palette is legible no matter what's behind it or what mode
        // macOS is in.
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

        // Fix 4 (v1.4.1): an OPAQUE dark layer on top of the vibrancy blur.
        // `darkAqua` above fixes the material's own tint, but a HUD-material
        // NSVisualEffectView is still translucent — enough of a light desktop
        // could still bleed through and wash out the cream text. This solid
        // fill (OpusTheme.panelBackground, 97% opaque) removes that
        // dependency entirely.
        let opaqueBG = NSView(frame: blur.bounds)
        opaqueBG.wantsLayer = true
        opaqueBG.layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        opaqueBG.layer?.cornerRadius = OpusTheme.radiusPanel
        opaqueBG.layer?.masksToBounds = true
        opaqueBG.autoresizingMask = [.width, .height]
        blur.addSubview(opaqueBG)

        let field = NSSearchField(frame: NSRect(x: OpusTheme.insetPanel, y: height - 42, width: width - 28, height: 28))
        field.autoresizingMask = [.width, .minYMargin]
        // Same field styling as FindBarView (spec section 5: "strictement
        // identique à celui de la barre de recherche").
        field.placeholderAttributedString = NSAttributedString(
            string: "Search conversations…",
            attributes: [.foregroundColor: OpusTheme.cream(0.45)]
        )
        field.toolTip = "Resumes in the shared session (tab 0); a private tab, if active, is left untouched."
        field.font = NSFont.systemFont(ofSize: 14)
        // Fix 4 (v1.4.1): explicit cream, not the adaptive control-text
        // color — same rationale as titleLabel/subtitleLabel above.
        field.textColor = OpusTheme.cream(0.95)
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
        // Fix 1 (v1.4.2): was `.none`, which silently disabled the table's
        // own click-to-select handling for a view-based table — clicking a
        // row never changed `selectedRow` at all (arrow keys/Enter still
        // worked because those go through our own doCommandBy handlers
        // below, calling selectRowIndexes directly, bypassing whatever
        // `.none` broke). `.regular` restores normal AppKit mouseDown →
        // selection handling. This does NOT bring back AppKit's own blue
        // highlight box — see SessionRowBackground's doc comment above for
        // why its drawSelection(in:) override already fully owns the
        // selected-row appearance regardless of this setting.
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

        // v1.4.2 task-review Finding 4 — clicking a palette row moves first
        // responder to the NSTableView (AppKit's normal click-to-select
        // behavior, restored by Fix 1 above), and a plain unsubclassed
        // NSTableView does NOT map Return to `doubleAction` the way a real
        // double-click does — so click-then-Enter could silently do
        // nothing. A LOCAL keyDown monitor scoped to this panel's window
        // makes Return/Escape/Up/Down handling independent of WHICHEVER
        // subview currently holds focus (search field or table): it sees
        // every keyDown before AppKit's normal responder-chain dispatch
        // (same mechanic as `TerminalContainerView.commandClickMonitor` —
        // see that monitor's own doc comment), so returning `nil` for these
        // four keys fully consumes them regardless of first responder.
        // Every other key returns the event UNTOUCHED so typing still
        // reaches the search field. Because this monitor runs first and
        // consumes Return/Escape/Up/Down outright, the search field
        // delegate's `control(_:textView:doCommandBy:)` handling for those
        // same commands (moveUp/moveDown/insertNewline/cancelOperation) can
        // never fire again — confirmed by how local monitors are documented
        // to run ahead of responder-chain dispatch — so that now-dead
        // method was removed below rather than left as unreachable
        // duplicate logic. Never removed once installed — this is a
        // singleton panel (`SessionSwitcherPanel.shared`) that lives for
        // the app's lifetime, same rationale as commandClickMonitor.
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
        allSessions = []
        filtered = []
        tableView.reloadData()

        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
        visible = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sessions = SessionIndex.scan(projectsDir: SessionSwitcherPanel.projectsDir)
            DispatchQueue.main.async {
                guard let self, self.visible, self.scanGeneration == generation else { return }
                self.allSessions = sessions
                self.applyFilter()
            }
        }
    }

    private func close() {
        visible = false
        panel.orderOut(nil)
    }

    // The "mouse" screen — same rationale/technique as QuickTerminalPanel's
    // activeScreen(): the palette should open on whichever monitor the user
    // is currently on, not wherever NSScreen.main happens to be.
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // MARK: Filtering

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filtered = allSessions
        } else {
            let tokens = query.lowercased().split(separator: " ").map(String.init)
            filtered = allSessions.filter { s in
                let haystack = (s.title + " " + s.cwd).lowercased()
                return tokens.allSatisfy { haystack.contains($0) }
            }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: Open selection

    @objc private func rowDoubleClicked() {
        openSelection()
    }

    private func openSelection() {
        let row = tableView.selectedRow
        guard filtered.indices.contains(row) else { return }
        let summary = filtered[row]
        OpusPreferences.shared.workingDirectory = summary.cwd
        ClaudeBackend.shared.restart(mode: .resume(sessionId: summary.sessionId))
        close()
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max(current + delta, 0), filtered.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }
}

// MARK: - NSSearchFieldDelegate (live filter)
//
// v1.4.2 task-review Finding 4 — this used to also implement
// `control(_:textView:doCommandBy:)` for moveUp/moveDown/insertNewline/
// cancelOperation (Up/Down/Return/Escape). That handling only ever fired
// while the search field itself held first responder — a clicked table row
// stole focus to the NSTableView, which doesn't forward Return through this
// delegate path at all (a plain NSTableView maps Return to nothing, not
// `doubleAction`), so click-then-Enter silently did nothing. Replaced by
// the local keyDown monitor installed at the end of `init` above, which is
// independent of first responder AND runs ahead of this delegate path in
// AppKit's dispatch order — so this method is now dead code for those four
// keys and was removed rather than left unreachable.

extension SessionSwitcherPanel: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension SessionSwitcherPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let summary = filtered[row]
        let cell: SessionCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? SessionCellView {
            cell = reused
        } else {
            cell = SessionCellView()
            cell.identifier = Self.cellID
        }
        let folder = (summary.cwd as NSString).lastPathComponent
        let branch = summary.gitBranch.map { " · \($0)" } ?? ""
        let relative = Self.relativeFormatter.localizedString(for: summary.mtime, relativeTo: Date())
        cell.configure(title: summary.title, subtitle: "\(folder)\(branch) · \(relative)")
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SessionRowBackground()
    }
}
