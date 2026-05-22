// Opus — native macOS launcher for Claude Code.
//
// Hotkeys (Scope L, scaffolding phase):
//   - Cmd+Ctrl+T        → toggle Ghostty's Quick Terminal (Apple Events). Current production path.
//   - Cmd+Ctrl+Shift+T  → toggle the native Opus panel (NSPanel slide-down). Development scaffold.
//
// Once the native panel reaches feature parity (Task 7), Cmd+Ctrl+T cuts over to native and
// the Ghostty Apple Event path is removed.

import Cocoa
import Carbon
import SwiftTerm

// MARK: - Quick Terminal Panel (SwiftTerm embedded)

// NSPanel returns false for canBecomeKey by default, which means it can't
// receive keyboard input. Override so our panel takes focus when shown.
private final class OpusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }   // it's a panel, not a window
    override var acceptsFirstResponder: Bool { true }
    // Cocoa's frame animation duration. Default proportional to size delta;
    // we hard-code a snappy 0.2s for the slide.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.20 }
}

// Minimal tab bar — a row of pill segments showing each tab's title. Hidden
// when only one tab exists.
private final class OpusTabBar: NSView {
    var tabCount: Int = 1 { didSet { needsDisplay = true } }
    var activeIndex: Int = 0 { didSet { needsDisplay = true } }
    var titles: [String] = [] { didSet { needsDisplay = true } }
    var onSwitch: ((Int) -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard tabCount > 0 else { return }
        let segW = bounds.width / CGFloat(tabCount)
        for i in 0..<tabCount {
            let r = NSRect(x: CGFloat(i) * segW + 3, y: 3,
                           width: segW - 6, height: bounds.height - 6)
            let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
            let fill = (i == activeIndex)
                ? NSColor(red: 0.45, green: 0.7, blue: 0.85, alpha: 0.45)
                : NSColor(white: 1, alpha: 0.07)
            fill.setFill()
            path.fill()

            let raw = i < titles.count && !titles[i].isEmpty ? titles[i] : "Claude"
            let label = "\(i + 1)  \(raw)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: i == activeIndex ? 0.95 : 0.55)
            ]
            // Truncated centered draw within the segment (with horizontal padding).
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            para.lineBreakMode = .byTruncatingTail
            var attrsWithPara = attrs
            attrsWithPara[.paragraphStyle] = para
            let textRect = r.insetBy(dx: 8, dy: 0)
            let yOffset = (textRect.height - 14) / 2
            label.draw(
                with: NSRect(x: textRect.minX, y: textRect.minY + yOffset, width: textRect.width, height: 14),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attrsWithPara
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        let segW = bounds.width / CGFloat(max(1, tabCount))
        let idx = Int(loc.x / segW)
        if (0..<tabCount).contains(idx) { onSwitch?(idx) }
    }
}

// Per-tab private claude session for tabs 1+. We can't subclass
// LocalProcessTerminalView and override `dataReceived(slice:)` (that method is
// only `public`, not `open`), so we re-implement what LPT does internally:
// a bare TerminalView paired with our own LocalProcess. The wrapper acts as
// both LocalProcessDelegate (PTY → terminal) and TerminalViewDelegate
// (terminal → PTY) and runs the cursor-visibility filter on incoming bytes,
// keeping the caret visible inside the panel while claude's TUI is active.
private final class FilteredClaudeTab: NSObject, LocalProcessDelegate, TerminalViewDelegate {
    let terminal: TerminalView
    private var process: LocalProcess!
    weak var panel: QuickTerminalPanel?
    var title: String = "Claude"

    init(frame: NSRect, panel: QuickTerminalPanel) {
        self.terminal = TerminalView(frame: frame)
        self.panel = panel
        super.init()
        self.process = LocalProcess(delegate: self)
        self.terminal.terminalDelegate = self
    }

    func start() {
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-i", "-c", "cd ~/Documents/GitHub/ClaudeUltra && command claude"],
            environment: nil,
            execName: nil
        )
    }

    /// SIGHUP claude so it cleans up TUI state and exits before we drop the pane.
    func terminate() {
        if process?.shellPid ?? 0 > 0 { kill(process.shellPid, SIGHUP) }
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        let filtered = QuickTerminalPanel.stripCursorVisibilityToggles(slice)
        DispatchQueue.main.async { [weak self] in
            self?.terminal.feed(byteArray: filtered[...])
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel?.handlePrivateTabTerminated(self)
        }
    }

    func getWindowSize() -> winsize {
        let t = terminal.getTerminal()
        return winsize(ws_row: UInt16(t.rows), ws_col: UInt16(t.cols), ws_xpixel: 0, ws_ypixel: 0)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm sometimes fires this delegate with negative dimensions
        // during NSSplitView's first layout pass on a freshly-inserted pane
        // (the child is briefly zero-sized while the split solves). Skip those
        // — the next layout pass produces valid positive values and we'll
        // resize then.
        guard newCols > 0, newRows > 0 else { return }
        // Resize the PTY directly (same Mirror trick as ClaudeBackend) — LocalProcess
        // doesn't expose its master FD publicly.
        let mirror = Mirror(reflecting: process!)
        for child in mirror.children where child.label == "childfd" {
            if let fd = child.value as? Int32, fd >= 0 {
                var ws = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols),
                                 ws_xpixel: 0, ws_ypixel: 0)
                _ = ioctl(fd, TIOCSWINSZ, &ws)
            }
        }
        if process.shellPid > 0 { kill(process.shellPid, SIGWINCH) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        self.title = title
        panel?.updatePrivateTabTitle(self)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

// A single terminal pane within a tab. Panes can be arranged horizontally or
// vertically via Cmd+D / Cmd+Shift+D (nested NSSplitView). A pane is either:
// - shared : bare TerminalView fed by ClaudeBackend's subscriber broadcast
//   (used for tab 0's root, mirrored with Terminal.app via opus-attach)
// - private: owns its own claude through FilteredClaudeTab
//   (new tabs spawn one of these; every split also spawns one of these)
private final class TabPane {
    let terminal: TerminalView
    let wrapper: FilteredClaudeTab?            // non-nil → private claude
    fileprivate var sharedSubscription: UUID?  // non-nil → shared backend
    var title: String = "Claude"

    static func makeShared(frame: NSRect, panel: QuickTerminalPanel) -> TabPane {
        let pane = TabPane(frame: frame, wrapper: nil)
        pane.terminal.terminalDelegate = panel
        pane.sharedSubscription = ClaudeBackend.shared.subscribe { [weak pane] slice in
            let filtered = QuickTerminalPanel.stripCursorVisibilityToggles(slice)
            pane?.terminal.feed(byteArray: filtered[...])
        }
        return pane
    }

    static func makePrivate(frame: NSRect, panel: QuickTerminalPanel) -> TabPane {
        let wrapper = FilteredClaudeTab(frame: frame, panel: panel)
        return TabPane(frame: frame, wrapper: wrapper)
    }

    private init(frame: NSRect, wrapper: FilteredClaudeTab?) {
        if let wrapper {
            self.terminal = wrapper.terminal
        } else {
            self.terminal = TerminalView(frame: frame)
        }
        self.wrapper = wrapper
    }

    func start() { wrapper?.start() }

    /// SIGHUP the underlying claude so it cleans up before we drop the pane.
    func terminate() {
        wrapper?.terminate()
    }

    deinit {
        if let token = sharedSubscription {
            ClaudeBackend.shared.unsubscribe(token)
        }
    }
}

final class QuickTerminalPanel: NSObject, TerminalViewDelegate {
    private let panel: OpusPanel
    private var blurView: NSVisualEffectView!
    private var terminalArea: NSView!         // container for all tab views — shrinks when tab bar visible
    private var tabs: [NSView] = []                       // top-level view per tab — a TerminalView when the tab has 1 pane, an NSSplitView once it gets a Cmd+D / Cmd+Shift+D split
    private var tabPanes: [[TabPane]] = []                // all panes per tab (flat list); tab 0's first entry is the shared pane, everything else is private
    private var tabActivePaneIndex: [Int] = []            // saved active pane index per tab (so switching tabs restores focus to wherever the user was)
    private var tabTitles: [String] = []                  // mirrors `tabs` — title from terminal escape sequences of the *active* pane
    private var activeTabIndex: Int = 0
    private var tabBar: OpusTabBar!
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private var terminalAreaBottomConstraint: NSLayoutConstraint!
    private var keyMonitor: Any?
    private var visible = false

    // Currently-focused pane in the active tab.
    fileprivate var activePane: TabPane? {
        guard tabPanes.indices.contains(activeTabIndex) else { return nil }
        let panes = tabPanes[activeTabIndex]
        // Prefer firstResponder if it's one of our panes (handles click-to-focus
        // between splits without us tracking every NSResponder change).
        if let fr = panel.firstResponder as? TerminalView,
           let p = panes.first(where: { $0.terminal === fr }) {
            return p
        }
        let saved = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
        guard panes.indices.contains(saved) else { return panes.first }
        return panes[saved]
    }

    private var activeTerminal: TerminalView? { activePane?.terminal }

    override init() {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = screen.visibleFrame
        let height = visibleFrame.height * 0.4

        panel = OpusPanel(
            contentRect: NSRect(
                x: visibleFrame.origin.x,
                y: visibleFrame.maxY,            // start off-screen above
                width: visibleFrame.width,
                height: height
            ),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.level = .floating
        panel.isMovable = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        // Prevent macOS auto-window-tabbing UI from appearing with terminal titles.
        panel.tabbingMode = .disallowed
        panel.title = ""

        // NSVisualEffectView for native macOS vibrancy/blur. The terminal sits
        // INSIDE this view with padding so the blur edges show through.
        let blur = NSVisualEffectView(frame: panel.contentView!.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        // A subtle dark tint over the blur — keeps the terminal background readable.
        let tint = NSView(frame: blur.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 0.55).cgColor
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        panel.contentView = blur
        blurView = blur

        // Container for the terminals. Its height shrinks to make room for the
        // tab bar when 2+ tabs are open, so the tab bar never overlaps the
        // terminal output.
        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(area)
        let areaBottom = area.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: blur.topAnchor, constant: 14),
            area.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 14),
            area.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            areaBottom
        ])
        terminalArea = area
        terminalAreaBottomConstraint = areaBottom

        // Tab bar at the bottom of the blur — visible only when 2+ tabs.
        let bar = OpusTabBar(frame: .zero)
        bar.isHidden = true       // start hidden — we have 1 tab to begin with
        bar.alphaValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onSwitch = { [weak self] idx in self?.switchTab(to: idx) }
        blur.addSubview(bar)
        let heightC = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -6),
            heightC
        ])
        tabBar = bar
        tabBarHeightConstraint = heightC

        // Force layout so terminalArea has its initial bounds before we add tab 0.
        blur.layoutSubtreeIfNeeded()

        // Tab 0 starts with a single shared pane wired to ClaudeBackend (mirrored
        // with Terminal.app via opus-attach). The pane's subscriber strips
        // cursor-visibility toggles so the caret stays visible while claude's
        // TUI is active. Tabs 1+ and any split spawn a private claude instead.
        ClaudeBackend.shared.startIfNeeded()
        let pane0 = TabPane.makeShared(frame: terminalArea.bounds, panel: self)
        styleTerminal(pane0.terminal)
        terminalArea.addSubview(pane0.terminal)
        tabs.append(pane0.terminal)
        tabPanes.append([pane0])
        tabActivePaneIndex.append(0)
        tabTitles.append("Claude")

        // Cmd+T / Cmd+W / Cmd+1..9 intercept for tab management.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleKeyEvent(ev) ?? ev
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResignKey),
            name: NSWindow.didResignKeyNotification, object: panel
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidBecomeKey),
            name: NSWindow.didBecomeKeyNotification, object: panel
        )
        // Suppress autohide when the panel briefly loses key status due to a
        // macOS Space switch (otherwise the panel disappears as Andy swipes).
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    private var ignoreResignKeyUntil: Date?

    @objc private func spaceDidChange() {
        // Give ourselves a 600ms grace period — Space-transition resigns key
        // briefly, but the panel should remain visible on the new Space.
        ignoreResignKeyUntil = Date().addingTimeInterval(0.6)
    }

    @objc private func panelDidBecomeKey() {
        // Push the active pane's dimensions to claude — meaningful only if the
        // active pane is the shared one (no wrapper), since private panes own
        // their own PTYs and handle resize through their TerminalViewDelegate.
        guard let pane = activePane, pane.wrapper == nil else { return }
        let t = pane.terminal.getTerminal()
        ClaudeBackend.shared.setPrimarySize(cols: UInt16(t.cols), rows: UInt16(t.rows))
    }

    // Removes DECTCEM cursor hide (`\e[?25l`) and show (`\e[?25h`) sequences
    // from the byte stream. Claude code emits hide when entering its TUI; if
    // SwiftTerm processes that, the caret disappears inside the panel even
    // though the user is still typing into it. We strip both directions so the
    // caret state stays at SwiftTerm's "visible" default. Only the 6-byte
    // standalone form is matched — claude's TUI lib emits these as separate
    // sequences, not multi-param. If a future version chains them with `;`
    // params, extend this to parse the param list.
    fileprivate static func stripCursorVisibilityToggles(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(slice.count)
        var i = slice.startIndex
        while i < slice.endIndex {
            if slice.distance(from: i, to: slice.endIndex) >= 6 &&
               slice[i]                           == 0x1B &&
               slice[slice.index(i, offsetBy: 1)] == 0x5B &&
               slice[slice.index(i, offsetBy: 2)] == 0x3F &&
               slice[slice.index(i, offsetBy: 3)] == 0x32 &&
               slice[slice.index(i, offsetBy: 4)] == 0x35 {
                let last = slice[slice.index(i, offsetBy: 5)]
                if last == 0x6C || last == 0x68 {
                    i = slice.index(i, offsetBy: 6)
                    continue
                }
            }
            output.append(slice[i])
            i = slice.index(after: i)
        }
        return output
    }

    // MARK: Tab management

    private func terminalFrame() -> NSRect {
        return terminalArea.bounds
    }

    private func styleTerminal(_ t: TerminalView) {
        t.autoresizingMask = [.width, .height]
        t.nativeBackgroundColor = .clear
        t.nativeForegroundColor = NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 1.0)
        // Explicit caret color — the default can inherit the (clear) background
        // and become invisible. Use a warm cream that stays readable on blur.
        t.caretColor = NSColor(red: 0.96, green: 0.91, blue: 0.82, alpha: 1.0)
        t.caretTextColor = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1.0)
        t.allowMouseReporting = false
        if let font = NSFont(name: "MesloLGS NF", size: 14)
            ?? NSFont(name: "SF Mono", size: 14)
            ?? NSFont(name: "Menlo", size: 14) {
            t.font = font
        }
    }

    // Letter shortcuts match by character (works across layouts because
    // letter keys don't need Shift in any common Latin layout). Digit
    // shortcuts match by physical keyCode (AZERTY French puts digits behind
    // Shift, so chars without Shift would be "&é"#'(... — useless for matching).
    private static let kc_Digits: [UInt16: Int] = [
        18: 0,  // 1
        19: 1,  // 2
        20: 2,  // 3
        21: 3,  // 4
        23: 4,  // 5
        22: 5,  // 6
        26: 6,  // 7
        28: 7,  // 8
        25: 8,  // 9
    ]

    private func handleKeyEvent(_ ev: NSEvent) -> NSEvent? {
        guard ev.window === panel else { return ev }
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd alone — tab/pane lifecycle + tab switching.
        if mods == .command {
            if let chars = ev.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "t": spawnNewTab(); return nil
                case "w": closeActivePane(); return nil
                case "d": splitActivePane(vertical: true); return nil   // side-by-side (iTerm2 convention)
                default: break
                }
            }
            if let tabIdx = Self.kc_Digits[ev.keyCode] {
                switchTab(to: tabIdx)
                return nil
            }
        }
        // Cmd+Shift+D — split top/bottom.
        if mods == [.command, .shift],
           ev.charactersIgnoringModifiers?.lowercased() == "d" {
            splitActivePane(vertical: false)
            return nil
        }
        return ev
    }

    private func spawnNewTab() {
        let pane = TabPane.makePrivate(frame: terminalFrame(), panel: self)
        styleTerminal(pane.terminal)
        pane.terminal.isHidden = true
        terminalArea.addSubview(pane.terminal)
        pane.start()
        tabs.append(pane.terminal)
        tabPanes.append([pane])
        tabActivePaneIndex.append(0)
        tabTitles.append("Claude")
        switchTab(to: tabs.count - 1)
    }

    /// Close the currently-focused pane. If it's the last pane in its tab,
    /// close the tab too. The shared pane of tab 0 (the only one without a
    /// FilteredClaudeTab) is protected — it can't be closed.
    private func closeActivePane() {
        guard let pane = activePane else { return }
        closePane(pane)
    }

    fileprivate func closePane(_ pane: TabPane) {
        guard let tabIdx = tabPanes.firstIndex(where: { panes in panes.contains(where: { $0 === pane }) }),
              let paneIdx = tabPanes[tabIdx].firstIndex(where: { $0 === pane }) else { return }

        // Don't let the user kill the shared pane in tab 0 — that's the session
        // mirrored with Terminal.app via opus-attach.
        if tabIdx == 0 && pane.wrapper == nil { return }

        pane.terminate()

        let view = pane.terminal
        let parent = view.superview
        view.removeFromSuperview()
        if let parentSplit = parent as? NSSplitView {
            parentSplit.removeArrangedSubview(view)
        }
        tabPanes[tabIdx].remove(at: paneIdx)

        if tabPanes[tabIdx].isEmpty {
            // The tab itself has nothing left to show — drop it.
            tabs[tabIdx].removeFromSuperview()
            tabs.remove(at: tabIdx)
            tabPanes.remove(at: tabIdx)
            tabActivePaneIndex.remove(at: tabIdx)
            tabTitles.remove(at: tabIdx)
            if activeTabIndex >= tabs.count { activeTabIndex = max(0, tabs.count - 1) }
            switchTab(to: activeTabIndex)
        } else {
            // Refocus a neighbor pane in the same tab.
            let newIdx = min(paneIdx, tabPanes[tabIdx].count - 1)
            tabActivePaneIndex[tabIdx] = newIdx
            if activeTabIndex == tabIdx {
                panel.makeFirstResponder(tabPanes[tabIdx][newIdx].terminal)
            }
            refreshActiveTabTitle()
        }
    }

    /// Cmd+D (vertical=true, panes side by side) / Cmd+Shift+D (vertical=false,
    /// panes top/bottom). Splits the active pane and spawns a private claude in
    /// the new half. Splits nest: if the active pane's parent NSSplitView
    /// already runs along the requested axis we just append; otherwise we wrap
    /// the active pane in a new perpendicular NSSplitView (iTerm2 behavior).
    private func splitActivePane(vertical: Bool) {
        guard let oldPane = activePane,
              tabPanes.indices.contains(activeTabIndex) else { return }

        let oldView = oldPane.terminal
        let parent = oldView.superview
        // Inherit oldView's frame so the new pane never starts at zero size —
        // NSSplitView would briefly hand a 0×0 child to SwiftTerm otherwise,
        // and its size-change calc can produce negative cols/rows during that
        // first layout pass (which is what makes the UInt16 conversion crash).
        let newPane = TabPane.makePrivate(frame: oldView.frame, panel: self)
        styleTerminal(newPane.terminal)
        newPane.start()

        if let parentSplit = parent as? NSSplitView, parentSplit.isVertical == vertical {
            // Same axis — extend the existing split.
            let idx = (parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0) + 1
            parentSplit.insertArrangedSubview(newPane.terminal, at: idx)
        } else if let parentSplit = parent as? NSSplitView {
            // Different axis — wrap old pane in a perpendicular split.
            let idx = parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0
            parentSplit.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
            let inner = NSSplitView()
            inner.isVertical = vertical
            inner.dividerStyle = .thin
            inner.addArrangedSubview(oldView)
            inner.addArrangedSubview(newPane.terminal)
            parentSplit.insertArrangedSubview(inner, at: idx)
        } else {
            // Old view is the tab's top-level — promote it inside a new NSSplitView.
            let root = NSSplitView(frame: oldView.frame)
            root.isVertical = vertical
            root.dividerStyle = .thin
            root.autoresizingMask = oldView.autoresizingMask
            oldView.removeFromSuperview()
            root.addArrangedSubview(oldView)
            root.addArrangedSubview(newPane.terminal)
            terminalArea.addSubview(root)
            tabs[activeTabIndex] = root
        }

        tabPanes[activeTabIndex].append(newPane)
        tabActivePaneIndex[activeTabIndex] = tabPanes[activeTabIndex].count - 1
        panel.makeFirstResponder(newPane.terminal)
        refreshActiveTabTitle()
    }

    private func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else { return }

        // Before we leave the current tab, remember which pane has focus so we
        // can restore it next time the user comes back.
        let prev = activeTabIndex
        if tabPanes.indices.contains(prev),
           let fr = panel.firstResponder as? TerminalView,
           let paneIdx = tabPanes[prev].firstIndex(where: { $0.terminal === fr }) {
            tabActivePaneIndex[prev] = paneIdx
        }

        for (i, view) in tabs.enumerated() { view.isHidden = (i != index) }
        activeTabIndex = index
        refreshActiveTabTitle()
        updateTabIndicator()

        guard tabPanes.indices.contains(index) else { return }
        let savedIdx = tabActivePaneIndex.indices.contains(index) ? tabActivePaneIndex[index] : 0
        let panes = tabPanes[index]
        guard panes.indices.contains(savedIdx) else { return }
        let pane = panes[savedIdx]
        panel.makeFirstResponder(pane.terminal)

        // Shared pane → push its dimensions back to the broadcast PTY.
        if pane.wrapper == nil {
            ClaudeBackend.shared.setPrimarySize(
                cols: UInt16(pane.terminal.getTerminal().cols),
                rows: UInt16(pane.terminal.getTerminal().rows)
            )
        }
    }

    /// Recompute the active tab's title from its currently-active pane.
    private func refreshActiveTabTitle() {
        guard tabPanes.indices.contains(activeTabIndex),
              tabActivePaneIndex.indices.contains(activeTabIndex) else { return }
        let idx = tabActivePaneIndex[activeTabIndex]
        let panes = tabPanes[activeTabIndex]
        guard panes.indices.contains(idx) else { return }
        tabTitles[activeTabIndex] = panes[idx].title
        tabBar.titles = tabTitles
    }

    private func updateTabIndicator() {
        tabBar.tabCount = tabs.count
        tabBar.activeIndex = activeTabIndex
        tabBar.titles = tabTitles
        // Show the bar only when 2+ tabs; shrink terminalArea to make room.
        let showBar = tabs.count > 1
        tabBar.isHidden = !showBar
        tabBar.alphaValue = showBar ? 1 : 0
        tabBarHeightConstraint.constant = showBar ? 26 : 0
        terminalAreaBottomConstraint.constant = showBar ? -(14 + 26 + 4) : -14
        tabBar.needsDisplay = true
        blurView.layoutSubtreeIfNeeded()
    }

    // MARK: Private pane callbacks (FilteredClaudeTab → panel)

    fileprivate func handlePrivateTabTerminated(_ wrapper: FilteredClaudeTab) {
        // The claude inside a private pane exited — close just that pane (and
        // the tab if it was the only pane left).
        for paneList in tabPanes {
            if let pane = paneList.first(where: { $0.wrapper === wrapper }) {
                closePane(pane)
                return
            }
        }
    }

    fileprivate func updatePrivateTabTitle(_ wrapper: FilteredClaudeTab) {
        for (tabIdx, paneList) in tabPanes.enumerated() {
            guard let pane = paneList.first(where: { $0.wrapper === wrapper }) else { continue }
            pane.title = wrapper.title
            let activeIdx = tabActivePaneIndex.indices.contains(tabIdx) ? tabActivePaneIndex[tabIdx] : 0
            if paneList.indices.contains(activeIdx) && paneList[activeIdx] === pane {
                tabTitles[tabIdx] = wrapper.title
                tabBar.titles = tabTitles
            }
            return
        }
    }


    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        ClaudeBackend.shared.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Same guard as FilteredClaudeTab: skip negative/zero transients from
        // NSSplitView's first layout pass to avoid UInt16 conversion traps.
        guard newCols > 0, newRows > 0 else { return }
        ClaudeBackend.shared.setPrimarySize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        // Called for shared panes (their terminalDelegate is the panel itself).
        // Private panes route titles through their own FilteredClaudeTab which
        // forwards to `updatePrivateTabTitle`.
        for (tabIdx, paneList) in tabPanes.enumerated() {
            guard let pane = paneList.first(where: { $0.terminal === source }) else { continue }
            pane.title = title
            let activeIdx = tabActivePaneIndex.indices.contains(tabIdx) ? tabActivePaneIndex[tabIdx] : 0
            if paneList.indices.contains(activeIdx) && paneList[activeIdx] === pane {
                tabTitles[tabIdx] = title
                tabBar.titles = tabTitles
            }
            return
        }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }

    private func processTerminatedShim() {
        // ClaudeBackend handles process exit; panel just hides.
        DispatchQueue.main.async { [weak self] in self?.hide() }
    }

    func toggle() {
        visible ? hide() : show()
    }

    // The "mouse" screen — matches Ghostty's quick-terminal-screen=mouse so the
    // panel always slides down on whichever monitor the user is currently using.
    private func activeScreenFrame() -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        return screen.visibleFrame
    }

    private func show() {
        let frame = activeScreenFrame()
        let h = frame.height * 0.4
        let w = frame.width

        let start  = NSRect(x: frame.origin.x, y: frame.maxY,     width: w, height: h)
        let target = NSRect(x: frame.origin.x, y: frame.maxY - h, width: w, height: h)

        // Layer-backed content for Core Animation. The panel itself stays at
        // target frame; we animate the content layer's translation to fake the
        // slide (Cocoa's frame animation is unreliable on borderless panels
        // since macOS 14+, so we do CA directly).
        panel.setFrame(target, display: true)
        panel.contentView?.wantsLayer = true

        guard let layer = panel.contentView?.layer else { return }
        let translateUp = CATransform3DMakeTranslation(0, h, 0)

        // Start hidden: translated above + alpha 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = translateUp
        panel.alphaValue = 0
        CATransaction.commit()

        // orderFrontRegardless + makeKey shows the panel on the CURRENT Space
        // without triggering a Space switch back to the panel's "home Space".
        // Combined with .nonactivatingPanel + canBecomeKey override, the panel
        // takes keyboard focus without activating Opus as the foreground app.
        panel.orderFrontRegardless()
        panel.makeKey()
        if let terminal = activeTerminal { panel.makeFirstResponder(terminal) }
        visible = true

        // CABasicAnimation for slide
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: translateUp)
        slide.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.duration = 0.22
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        slide.fillMode = .both
        layer.add(slide, forKey: "slideIn")

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        // Parallel alpha fade-in — combined with the slide for a clean show.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        // When the panel hides, the user is likely going back to Terminal.app
        // (or whatever else they had). Trigger a resize so claude redraws for
        // the new front app — covers the case where activeAppDidChange doesn't
        // fire (.nonactivatingPanel means Opus never "actives" as an app).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AppDelegate.shared?.resizeClaudeForFrontmostApp()
        }

        guard let layer = panel.contentView?.layer else {
            visible = false
            panel.orderOut(nil)
            return
        }
        let h = panel.frame.height
        visible = false

        // Slide content back up + fade out
        let slide = CABasicAnimation(keyPath: "transform")
        slide.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        slide.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(0, h, 0))
        slide.duration = 0.18
        slide.timingFunction = CAMediaTimingFunction(name: .easeIn)
        slide.fillMode = .both
        slide.isRemovedOnCompletion = false
        layer.add(slide, forKey: "slideOut")

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.contentView?.layer?.removeAllAnimations()
        })
    }

    @objc private func panelDidResignKey() {
        if let until = ignoreResignKeyUntil, until > Date() {
            return  // resign caused by Space switch — don't autohide
        }
        if visible { hide() }
    }
}

// MARK: - Carbon hotkey callback

private let hotkeyCallback: EventHandlerUPP = { (_, _, _) -> OSStatus in
    DispatchQueue.main.async {
        AppDelegate.shared?.toggleNativePanel()
    }
    return noErr
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private var nativePanel: QuickTerminalPanel?
    private let socketServer = SocketServer()

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self

        // Kill any stale dtach/socket leftovers so each launch is fresh.
        killStaleSessionIfOrphaned()

        // Start the Unix socket server so external clients (opus-attach in
        // Terminal.app) can subscribe to the same claude session as the panel.
        socketServer.start()

        // Phase 3b — focus-following resize for Terminal.app. When Terminal.app
        // becomes the active app, query its front window's cols/rows and resize
        // claude's PTY so the rendering matches.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeAppDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        nativePanel = QuickTerminalPanel()
        registerHotkey()
        launchTerminalSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.nativePanel?.toggle()
        }
    }

    private func killStaleSessionIfOrphaned() {
        // Kill any existing dtach master holding the opus.sock — guarantees a
        // fresh claude on each Opus launch. We do this unconditionally because
        // dtach doesn't expose client count and Andy explicitly disliked the
        // "old claude on relaunch" behavior.
        let kill = Process()
        kill.launchPath = "/usr/bin/pkill"
        kill.arguments = ["-f", "dtach -[Aa] /tmp/opus.sock"]
        kill.standardError = Pipe()
        try? kill.run()
        kill.waitUntilExit()
        // Clean up the stale socket file too (defensive — dtach cleans on exit).
        try? FileManager.default.removeItem(atPath: "/tmp/opus.sock")
        NSLog("Opus: killed any stale dtach master on /tmp/opus.sock")
    }

    // Subsequent Dock/Finder clicks on Opus toggle the panel only — no extra
    // Terminal windows. If you want another main window, open Terminal manually
    // and type `claude` (.zshrc wrapper joins the shared session).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        nativePanel?.toggle()
        return true
    }

    // Terminal.app's size is reported event-driven by opus-attach itself (it
    // sends a control message on connect and on every SIGWINCH). We no longer
    // poll — see SocketServer.handleClient + opus-attach for the wire protocol.
    @objc private func activeAppDidChange(_ notification: Notification) {
        // Kept as a no-op handler in case we ever add other per-app behavior.
        // The actual resize is driven by opus-attach SIGWINCH → socket message.
    }

    /// Called when the panel hides — re-trigger the focused TerminalView's
    /// size hint by querying its current cols/rows.
    func resizeClaudeForFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.Terminal" else { return }
        let source = """
        tell application "Terminal"
            if not (exists front window) then return "0,0"
            set t to selected tab of front window
            return ((number of columns of t) as text) & "," & ((number of rows of t) as text)
        end tell
        """
        var err: NSDictionary?
        let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&err)
        guard let result = descriptor?.stringValue else { return }
        let parts = result.split(separator: ",")
        guard parts.count == 2,
              let cols = UInt16(parts[0]),
              let rows = UInt16(parts[1]),
              cols > 10, rows > 5
        else { return }
        ClaudeBackend.shared.setPrimarySize(cols: cols, rows: rows)
    }

    private func launchTerminalSession() {
        // Open Terminal.app and run opus-attach, which connects to our socket
        // server and bridges Terminal.app's TTY to the shared claude session.
        // No tmux, no dtach — direct subscriber to the same backend the panel uses.
        let source = """
        tell application "Terminal"
            activate
            do script "opus-attach"
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if err != nil {
            NSLog("Opus: failed to open Terminal.app session")
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        socketServer.stop()
        if let ref = hotKeyRef  { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }

    // MARK: Actions

    func toggleNativePanel() {
        nativePanel?.toggle()
    }

    // MARK: Setup

    private func registerHotkey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyCallback,
            1, &spec, nil, &handlerRef
        )

        // Cmd+Ctrl+T → native QT panel (the only hotkey; post-Ghostty cutover).
        let id = EventHotKeyID(signature: OSType(0x4F505553), id: 1)
        let status = RegisterEventHotKey(
            17,                                    // kVK_ANSI_T
            UInt32(cmdKey | controlKey),
            id, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        NSLog("Opus hotkey Cmd+Ctrl+T registered (status=\(status))")
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .regular = Opus shows in the Dock with a running indicator while alive.
// Combined with removing LSUIElement from Info.plist, the pinned icon gets
// the standard "running" dot. Use .accessory if you want truly invisible.
app.setActivationPolicy(.regular)
app.run()
