import AppKit
import OpusScriptsKit

// The scripts panel: everything in ~/.opus/scripts, listed, launchable, and
// watchable while it runs.
//
// Deliberately self-contained. An earlier design ran output-producing scripts
// in a real Opus tab to inherit SwiftTerm's colours and scrollback, but that
// meant reaching into TabPane and TerminalContainerView — the terminal the owner
// uses all day. Risking his daily driver to gain ANSI colour in a log pane is
// a bad trade, so this panel owns its own output view and touches nothing
// outside itself. The cost, stated plainly: output here is plain text.
//
// Four traps this panel inherits as SOLVED from SecretsPanel, all of which
// shipped broken there first:
//  - reloadData() drops NSTableView's selection, so selection is preserved by
//    IDENTITY across every reload, never by row index
//  - column widths are constants, never measured from displayed content, or
//    the list lurches sideways whenever a row's text changes
//  - a non-activating panel does not lose key when Opus's own window is
//    clicked, so dismissal watches the click as well as the notification
//  - row buttons must accept first mouse and refuse first responder

/// A borderless, non-activating panel. Same shape as the secrets panel: it can
/// take keys, but it is never the app's main window.
private final class ScriptsPanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Row background that draws the selection itself — the system's default
/// highlight is a blue that belongs to no part of this app's palette.
private final class ScriptRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        OpusTheme.cream(0.10).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1),
                     xRadius: OpusTheme.radiusControl, yRadius: OpusTheme.radiusControl).fill()
    }
}

/// A 20x20 icon button that brightens on hover.
///
/// `acceptsFirstMouse` matters because the panel is non-activating: without
/// it macOS eats the first click as an activation click and the button appears
/// dead until clicked twice. `refusesFirstResponder` matters because the
/// filter field must keep the caret — a button that steals focus turns the
/// next keystroke into nothing.
private final class ScriptIconButton: NSButton {
    var restingTint: NSColor = OpusTheme.cream(0.55) { didSet { applyTint(hovering: false) } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        translatesAutoresizingMaskIntoConstraints = false
        refusesFirstResponder = true
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { applyTint(hovering: true) }
    override func mouseExited(with event: NSEvent) { applyTint(hovering: false) }

    private func applyTint(hovering: Bool) {
        contentTintColor = hovering ? restingTint.withAlphaComponent(1.0) : restingTint
    }
}

private func makeScriptButton(symbol: String, tint: NSColor,
                              label: String, toolTip: String) -> ScriptIconButton {
    let button = ScriptIconButton(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    image?.isTemplate = true
    button.image = image
    button.restingTint = tint
    button.setAccessibilityLabel(label)
    button.toolTip = toolTip
    NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 20),
        button.heightAnchor.constraint(equalToConstant: 20),
    ])
    return button
}

/// One row: name, summary, state, and a run/stop button.
///
/// Every column width here is a CONSTANT. Measuring them from the text on
/// screen makes the whole list shift sideways the moment any row's state text
/// changes from "prêt" to "en cours depuis 1 min", which happens once a second
/// while something runs.
private final class ScriptRowCellView: NSTableCellView {
    static let nameColumnWidth: CGFloat = 170
    static let stateColumnWidth: CGFloat = 150

    private let nameLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    let actionButton: ScriptIconButton

    override init(frame frameRect: NSRect) {
        actionButton = makeScriptButton(symbol: "play.fill", tint: OpusTheme.green,
                                        label: "lancer ce script", toolTip: "Lancer (↩)")
        super.init(frame: frameRect)

        for (label, font, color) in [
            (nameLabel, NSFont.systemFont(ofSize: 12, weight: .medium), OpusTheme.cream(0.85)),
            (summaryLabel, NSFont.systemFont(ofSize: 11), OpusTheme.cream(0.45)),
            (stateLabel, NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), OpusTheme.cream(0.5)),
        ] as [(NSTextField, NSFont, NSColor)] {
            label.font = font
            label.textColor = color
            label.alignment = .left
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isSelectable = false
            label.refusesFirstResponder = true
            addSubview(label)
        }
        addSubview(actionButton)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.nameColumnWidth),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 10),
            summaryLabel.trailingAnchor.constraint(equalTo: stateLabel.leadingAnchor, constant: -10),
            summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            stateLabel.widthAnchor.constraint(equalToConstant: Self.stateColumnWidth),
            stateLabel.trailingAnchor.constraint(equalTo: actionButton.leadingAnchor, constant: -8),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actionButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(name: String, summary: String, state: ScriptRunState) {
        nameLabel.stringValue = name
        summaryLabel.stringValue = summary
        let described = ScriptsPanel.describe(state, now: Date())
        stateLabel.stringValue = described.text
        stateLabel.textColor = described.color

        let running = state.isRunning
        let symbol = running ? "stop.fill" : "play.fill"
        let label = running ? "arrêter ce script" : "lancer ce script"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        actionButton.image = image
        actionButton.restingTint = running ? OpusTheme.red : OpusTheme.green
        actionButton.setAccessibilityLabel(label)
        actionButton.toolTip = running ? "Arrêter (↩)" : "Lancer (↩)"
    }
}

final class ScriptsPanel: NSObject {
    static let shared = ScriptsPanel()

    private static let rowCellID = NSUserInterfaceItemIdentifier("ScriptRow")
    private static let width: CGFloat = 620
    private static let topMargin: CGFloat = 20
    /// kVK_ANSI_F — Cmd+F focuses the filter, matching every other panel.
    private static let filterKeyCode: UInt16 = 3

    private let panel: ScriptsPanelWindow
    private let titleLabel = NSTextField(labelWithString: "Scripts")
    private let searchField = NSSearchField()
    private let headerLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let separator = NSBox()
    private let outputHeaderLabel = NSTextField(labelWithString: "")
    private let outputView = NSTextView()
    private let outputScrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "")

    private var scripts: [ScriptDefinition] = []
    private var filtered: [ScriptDefinition] = []
    /// Selection is tracked by script IDENTITY, never by row index. Every
    /// reload would otherwise silently move the selection onto a different
    /// script — and the run button acts on the selection.
    private var selectedScriptID: String?
    private var isRestoringSelection = false
    private var scanProblem: String?
    /// Derived from the window, never stored. A stored flag drifted out of
    /// step with what was on screen — the panel stayed visible while the
    /// flag said closed, so the toggle inverted and keystrokes went to the
    /// window behind it. The window itself cannot lie about being visible.
    private var isOpen: Bool { panel.isVisible && panel.alphaValue > 0.01 }
    private var previousKeyWindow: NSWindow?
    private var keyMonitor: Any?
    private var clickAwayMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var runnerObserver: NSObjectProtocol?
    private var tickTimer: Timer?

    private override init() {
        panel = ScriptsPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildWindow()
        buildViews()
        installMonitors()
    }

    // MARK: Construction

    private func buildWindow() {
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

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 520))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = OpusTheme.radiusPanel
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        panel.contentView = blur

        let opaque = NSView(frame: blur.bounds)
        opaque.wantsLayer = true
        opaque.layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        opaque.layer?.cornerRadius = OpusTheme.radiusPanel
        opaque.autoresizingMask = [.width, .height]
        blur.addSubview(opaque)
    }

    private func buildViews() {
        guard let root = panel.contentView else { return }

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = OpusTheme.cream(0.9)
        root.addSubview(titleLabel)

        searchField.placeholderString = "filtrer"
        searchField.font = NSFont.systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.delegate = self
        root.addSubview(searchField)

        headerLabel.font = NSFont.systemFont(ofSize: 11)
        headerLabel.textColor = OpusTheme.cream(0.5)
        root.addSubview(headerLabel)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("script"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 26
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        separator.boxType = .separator
        root.addSubview(separator)

        outputHeaderLabel.font = NSFont.systemFont(ofSize: 11)
        outputHeaderLabel.textColor = OpusTheme.cream(0.5)
        root.addSubview(outputHeaderLabel)

        outputView.isEditable = false
        // Selectable so the user can copy a stack trace out. Not editable, so
        // the caret never lands here and the filter keeps focus.
        outputView.isSelectable = true
        outputView.drawsBackground = true
        outputView.backgroundColor = OpusTheme.fieldBackground
        outputView.textColor = OpusTheme.cream(0.75)
        outputView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        outputView.textContainerInset = NSSize(width: 6, height: 6)
        outputView.isVerticallyResizable = true
        outputView.autoresizingMask = [.width]
        outputScrollView.documentView = outputView
        outputScrollView.hasVerticalScroller = true
        outputScrollView.autohidesScrollers = true
        outputScrollView.drawsBackground = false
        outputScrollView.wantsLayer = true
        outputScrollView.layer?.cornerRadius = OpusTheme.radiusControl
        outputScrollView.layer?.masksToBounds = true
        root.addSubview(outputScrollView)

        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = OpusTheme.cream(0.5)
        hintLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(hintLabel)
    }

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handleKey(event)
        }

        // Switching apps: the panel loses key and goes away.
        //
        // Re-checked one run-loop tick later, and that delay is the whole
        // point. A window resigns key for reasons that are not the user
        // leaving — a scripted AppleScript query, an accessibility client
        // attaching, a transient system panel. Closing on the raw
        // notification meant the panel stayed on screen while its state said
        // "closed", after which keystrokes went to the terminal behind it
        // instead of the panel the user was looking at. Confirming that the
        // panel is still not key on the next tick absorbs the blips and keeps
        // the real case (focus genuinely moved elsewhere) working.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.isOpen else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isOpen, !self.panel.isKeyWindow else { return }
                self.close(restoringFocus: false)
            }
        }

        // Clicking Opus's own terminal window: that window never takes key
        // from a non-activating panel, so the notification above never fires
        // for the most common dismissal of all. The click is passed through
        // untouched — it is the user's click, not a dismiss gesture.
        clickAwayMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isOpen, event.window !== self.panel else { return event }
            self.close(restoringFocus: false)
            return event
        }

        runnerObserver = NotificationCenter.default.addObserver(
            forName: ScriptRunner.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isOpen else { return }
            self.reloadTableContent()
            self.updateHeader()
            self.updateOutputPane()
            self.updateHint()
        }
    }

    // MARK: Opening and closing

    func toggle() { isOpen ? close() : open() }

    private func open() {
        guard !isOpen else { return }
        // Created on demand: the folder not existing is the normal state right
        // up until the first script is written, and a panel that reports that
        // as a problem would be reporting its own first run as a failure.
        try? FileManager.default.createDirectory(
            at: ScriptRegistry.defaultDirectory, withIntermediateDirectories: true)

        searchField.stringValue = ""
        rescan()
        relayout()

        previousKeyWindow = NSApp.keyWindow
        animateAppear()
        panel.makeFirstResponder(searchField)

        // One tick a second, only while open: "en cours depuis 3 min" has to
        // stay true, and there is nothing else driving a repaint.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isOpen, ScriptRunner.shared.runningCount > 0 else { return }
            self.reloadTableContent()
            self.updateHeader()
        }
    }

    private func close(restoringFocus: Bool = true) {
        tickTimer?.invalidate()
        tickTimer = nil
        searchField.stringValue = ""

        // Never restore focus when the panel is closing BECAUSE focus went
        // elsewhere: that would rip it back off whatever was just clicked.
        if restoringFocus, let previous = previousKeyWindow, previous.isVisible { previous.makeKey() }
        previousKeyWindow = nil

        // alphaValue is what isOpen reads, so drive it to zero FIRST: the
        // panel must read as closed the instant close() is called, even
        // though it keeps fading for another 90ms.
        animateDismiss { [weak self] in
            guard let self, self.panel.alphaValue < 0.01 else { return }
            self.panel.orderOut(nil)
        }
    }

    // MARK: Data

    private func rescan() {
        do {
            scripts = try ScriptRegistry.scan(directory: ScriptRegistry.defaultDirectory)
            scanProblem = nil
        } catch {
            // Surfaced in red rather than swallowed: an unreadable folder that
            // presents as "no scripts" is indistinguishable from an empty one,
            // and the user would go looking for a file they already wrote.
            scripts = []
            scanProblem = "dossier illisible : \(error.localizedDescription)"
        }
        applyFilter()
    }

    private func applyFilter() {
        filtered = ScriptRegistry.filter(scripts, query: searchField.stringValue)
        if let selectedScriptID, !filtered.contains(where: { $0.id == selectedScriptID }) {
            self.selectedScriptID = nil
        }
        if selectedScriptID == nil { selectedScriptID = filtered.first?.id }
        reloadTableContent()
        updateHeader()
        updateOutputPane()
        updateHint()
    }

    /// Reloads, then puts the selection back where it was.
    ///
    /// reloadData() drops NSTableView's selection, and the run button, Enter,
    /// and the output pane all read it. Restoring by ID rather than by index
    /// matters because a reload can follow a filter change, after which the
    /// old index points at a different script entirely.
    private func reloadTableContent() {
        tableView.reloadData()
        guard let selectedScriptID,
              let row = filtered.firstIndex(where: { $0.id == selectedScriptID }) else { return }
        isRestoringSelection = true
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isRestoringSelection = false
    }

    private var selectedScript: ScriptDefinition? {
        guard let selectedScriptID else { return nil }
        return filtered.first { $0.id == selectedScriptID }
    }

    // MARK: Display

    /// The one place a run state becomes words. Shared by the row and the
    /// output header so the two can never disagree about what is happening.
    static func describe(_ state: ScriptRunState, now: Date) -> (text: String, color: NSColor) {
        switch state {
        case .idle:
            return ("prêt", OpusTheme.cream(0.4))
        case .running(let since):
            return ("● en cours · \(elapsed(since: since, now: now))", OpusTheme.green)
        case .finished(let code, let signal, _):
            if signal == SIGTERM { return ("arrêté", OpusTheme.amber) }
            if let signal { return ("tué (signal \(signal))", OpusTheme.red) }
            return code == 0 ? ("terminé", OpusTheme.cream(0.4))
                             : ("échec (code \(code))", OpusTheme.red)
        }
    }

    static func elapsed(since: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }

    private func updateHeader() {
        if let scanProblem {
            headerLabel.textColor = OpusTheme.red
            headerLabel.stringValue = scanProblem
            return
        }
        headerLabel.textColor = OpusTheme.cream(0.5)
        if scripts.isEmpty {
            headerLabel.stringValue = "aucun script — dépose un fichier exécutable dans ~/.opus/scripts/"
            return
        }
        var parts = [filtered.count == scripts.count
                        ? "\(scripts.count) script\(scripts.count > 1 ? "s" : "")"
                        : "\(filtered.count) sur \(scripts.count)"]
        let running = ScriptRunner.shared.runningCount
        if running > 0 { parts.append("\(running) en cours") }
        headerLabel.stringValue = parts.joined(separator: " · ")
    }

    private func updateOutputPane() {
        guard let script = selectedScript else {
            outputHeaderLabel.stringValue = ""
            outputView.string = ""
            return
        }
        let state = ScriptRunner.shared.state(of: script)
        let buffer = ScriptRunner.shared.output(of: script)
        outputHeaderLabel.stringValue = buffer.truncated
            ? "sortie de « \(script.displayName) » · début tronqué"
            : "sortie de « \(script.displayName) »"
        outputHeaderLabel.textColor = buffer.truncated ? OpusTheme.amber : OpusTheme.cream(0.5)

        let text = buffer.text.isEmpty
            ? (state.isRunning ? "(pas encore de sortie)" : "(aucune sortie)")
            : buffer.text
        guard outputView.string != text else { return }

        // Only follow the tail when the user is ALREADY at the bottom. Yanking
        // the view down while they are reading something further up is the
        // single most irritating thing a log pane can do.
        let atBottom = isOutputScrolledToBottom()
        outputView.string = text
        if atBottom { outputView.scrollToEndOfDocument(nil) }
    }

    private func isOutputScrolledToBottom() -> Bool {
        let clip = outputScrollView.contentView
        let documentHeight = outputView.frame.height
        let visibleBottom = clip.bounds.origin.y + clip.bounds.height
        return documentHeight - visibleBottom < 24
    }

    /// State-aware, not a fixed legend: it only advertises what is actually
    /// possible right now.
    private func updateHint() {
        var parts: [String] = []
        if !filtered.isEmpty { parts.append("↑↓ parcourir") }
        if let script = selectedScript {
            parts.append(ScriptRunner.shared.state(of: script).isRunning ? "↩ arrêter" : "↩ lancer")
        }
        parts.append("⌘F filtrer")
        parts.append("⎋ fermer")
        hintLabel.stringValue = parts.joined(separator: " · ")
    }

    // MARK: Layout

    private func relayout() {
        let inset = OpusTheme.insetPanel
        let contentWidth = Self.width - inset * 2
        let visibleRows = min(max(filtered.count, 1), 8)
        let listHeight = CGFloat(visibleRows) * (tableView.rowHeight + tableView.intercellSpacing.height)
        let outputHeight: CGFloat = 150

        var y: CGFloat = Self.topMargin
        var stacked: [(NSView, CGFloat, CGFloat)] = []
        func stack(_ view: NSView, height: CGFloat, gapAfter: CGFloat) {
            stacked.append((view, y, height))
            y += height + gapAfter
        }

        stack(titleLabel, height: 20, gapAfter: 14)
        stack(searchField, height: 26, gapAfter: 8)
        stack(headerLabel, height: 18, gapAfter: 6)
        stack(scrollView, height: listHeight, gapAfter: 12)
        stack(separator, height: 1, gapAfter: 10)
        stack(outputHeaderLabel, height: 16, gapAfter: 6)
        stack(outputScrollView, height: outputHeight, gapAfter: 10)
        stack(hintLabel, height: 16, gapAfter: 0)

        let height = y + inset
        for (view, top, viewHeight) in stacked {
            view.frame = NSRect(x: inset, y: height - top - viewHeight,
                                width: contentWidth, height: viewHeight)
        }

        let screen = (NSScreen.main ?? NSScreen.screens[0]).frame
        panel.setFrame(NSRect(x: screen.midX - Self.width / 2,
                              y: screen.midY - height / 2,
                              width: Self.width, height: height),
                       display: true)
    }

    // MARK: Animation

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

    private func animateDismiss(completion: @escaping () -> Void) {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 0
            completion()
            return
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = CATransform3DIdentity
        scale.toValue = CATransform3DMakeScale(0.98, 0.98, 1)
        scale.duration = 0.09
        scale.timingFunction = CAMediaTimingFunction(name: .easeIn)
        scale.fillMode = .forwards
        scale.isRemovedOnCompletion = false
        layer.add(scale, forKey: "dismissScale")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: completion)
    }

    // MARK: Input

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        if KeyMods.shortcutMods(event.modifierFlags) == .command,
           event.keyCode == Self.filterKeyCode {
            panel.makeFirstResponder(searchField)
            return nil
        }
        switch event.keyCode {
        case 53:    // Escape — progressive: clear a filter first, then close.
            if !searchField.stringValue.isEmpty {
                searchField.stringValue = ""
                applyFilter()
                relayout()
            } else {
                close()
            }
            return nil
        case 36, 76:    // Return / Enter
            if let script = selectedScript { run(script) }
            return nil
        case 125: moveSelection(by: 1); return nil
        case 126: moveSelection(by: -1); return nil
        default: return event
        }
    }

    private func moveSelection(by delta: Int) {
        guard !filtered.isEmpty else { return }
        let current = filtered.firstIndex { $0.id == selectedScriptID } ?? -1
        let next = min(max(current + delta, 0), filtered.count - 1)
        selectedScriptID = filtered[next].id
        isRestoringSelection = true
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        isRestoringSelection = false
        tableView.scrollRowToVisible(next)
        updateOutputPane()
        updateHint()
    }

    private func run(_ script: ScriptDefinition) {
        if let problem = ScriptRunner.shared.toggle(script) {
            outputHeaderLabel.textColor = OpusTheme.red
            outputHeaderLabel.stringValue = problem
        }
        reloadTableContent()
        updateHeader()
        updateOutputPane()
        updateHint()
    }

    @objc private func rowDoubleClicked() {
        guard filtered.indices.contains(tableView.clickedRow) else { return }
        run(filtered[tableView.clickedRow])
    }

    /// Resolved from the BUTTON, never from the current selection: the user
    /// can click row four's button while row one is selected, and acting on
    /// the selection there would run the wrong script.
    @objc private func actionButtonClicked(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard filtered.indices.contains(row) else { return }
        selectedScriptID = filtered[row].id
        run(filtered[row])
    }

    func stopAllOnQuit() { ScriptRunner.shared.stopAll() }
}

// MARK: - Table

extension ScriptsPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else { return nil }
        let script = filtered[row]
        let cell: ScriptRowCellView
        if let reused = tableView.makeView(withIdentifier: Self.rowCellID, owner: self) as? ScriptRowCellView {
            cell = reused
        } else {
            cell = ScriptRowCellView()
            cell.identifier = Self.rowCellID
            // Wired once per cell instance. The action resolves its row fresh
            // at CLICK time, so cell reuse across a reload can never fire on a
            // stale row.
            cell.actionButton.target = self
            cell.actionButton.action = #selector(actionButtonClicked(_:))
        }
        cell.configure(name: script.displayName,
                       summary: script.summary,
                       state: ScriptRunner.shared.state(of: script))
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ScriptRowBackground()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // reloadTableContent() re-applies the selection a reloadData() just
        // cleared. That is bookkeeping, not the user moving.
        guard !isRestoringSelection else { return }
        guard filtered.indices.contains(tableView.selectedRow) else { return }
        selectedScriptID = filtered[tableView.selectedRow].id
        updateOutputPane()
        updateHint()
    }
}

// MARK: - Filter field

extension ScriptsPanel: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSearchField) === searchField else { return }
        applyFilter()
        relayout()
    }
}
