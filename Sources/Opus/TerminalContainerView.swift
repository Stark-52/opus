// TerminalContainerView — owns the tabs/panes/splits and the bottom OpusTabBar.
// Hosts (QuickTerminalPanel, MainTerminalWindow) embed this view and forward
// key events / window callbacks via the TerminalContainerHost protocol.
//
// Task 12: new class introduced, NOT yet used by QuickTerminalPanel.
// Task 13: QuickTerminalPanel swaps its inline state for an embedded instance.
// Task 14: MainTerminalWindow embeds it too.

import AppKit
import SwiftTerm
import Darwin

protocol TerminalContainerHost: AnyObject {
    var hostWindow: NSWindow? { get }
    /// Called when the user wants to spawn a Terminal.app mirror of the
    /// shared session. Host may no-op (Standalone pairing, MainTerminalWindow).
    func openInTerminalRequested()
}

final class TerminalContainerView: NSView, TerminalViewDelegate {
    weak var host: TerminalContainerHost?

    private var terminalArea: NSView!
    private var tabBar: OpusTabBar!
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private var terminalAreaBottomConstraint: NSLayoutConstraint!

    private var tabs: [NSView] = []
    private var tabPanes: [[TabPane]] = []
    private var tabActivePaneIndex: [Int] = []
    private var tabTitles: [String] = []
    private var activeTabIndex: Int = 0

    /// True when this container is the tab-0 broadcast subscriber (panel host).
    /// MainTerminalWindow sets this to false to spawn a fully private tab 0.
    private let useSharedTab0: Bool

    init(frame: NSRect, useSharedTab0: Bool) {
        self.useSharedTab0 = useSharedTab0
        super.init(frame: frame)
        wantsLayer = true
        buildSubviews()
        bootstrapFirstTab()
        if useSharedTab0 {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sharedBackendDidTerminate(_:)),
                name: .claudeBackendDidTerminate, object: nil
            )
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Layout (new — container-specific)

    private func buildSubviews() {
        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        addSubview(area)
        let bottom = area.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: topAnchor),
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            area.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottom
        ])
        terminalArea = area
        terminalAreaBottomConstraint = bottom

        let bar = OpusTabBar(frame: .zero)
        bar.isHidden = true
        bar.alphaValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onSwitch = { [weak self] idx in self?.switchTab(to: idx) }
        addSubview(bar)
        let heightC = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 8),
            heightC
        ])
        tabBar = bar
        tabBarHeightConstraint = heightC

        layoutSubtreeIfNeeded()
    }

    private func bootstrapFirstTab() {
        if useSharedTab0 {
            ClaudeBackend.shared.startIfNeeded()
            let pane0 = TabPane.makeShared(frame: terminalArea.bounds, panel: nil, container: self)
            styleTerminal(pane0.terminal)
            terminalArea.addSubview(pane0.terminal)
            tabs.append(pane0.terminal)
            tabPanes.append([pane0])
            tabActivePaneIndex.append(0)
            tabTitles.append("Claude")
        } else {
            let pane0 = TabPane.makePrivate(frame: terminalArea.bounds, panel: nil, container: self)
            styleTerminal(pane0.terminal)
            terminalArea.addSubview(pane0.terminal)
            pane0.start()
            tabs.append(pane0.terminal)
            tabPanes.append([pane0])
            tabActivePaneIndex.append(0)
            tabTitles.append("Claude")
        }
    }

    // MARK: Public API (called by the host)

    var activePane: TabPane? {
        guard tabPanes.indices.contains(activeTabIndex) else { return nil }
        let panes = tabPanes[activeTabIndex]
        if let fr = window?.firstResponder as? TerminalView,
           let p = panes.first(where: { $0.terminal === fr }) { return p }
        let saved = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
        guard panes.indices.contains(saved) else { return panes.first }
        return panes[saved]
    }

    var activeTerminal: TerminalView? { activePane?.terminal }

    func spawnNewTab() {
        let pane = TabPane.makePrivate(frame: terminalFrame(), panel: nil, container: self)
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

    func closeActivePane() {
        guard let pane = activePane else { return }
        closePane(pane)
    }

    func closePane(_ pane: TabPane) {
        guard let tabIdx = tabPanes.firstIndex(where: { panes in panes.contains(where: { $0 === pane }) }),
              let paneIdx = tabPanes[tabIdx].firstIndex(where: { $0 === pane }) else { return }

        // Don't let the user kill the shared pane in tab 0 — that's the session
        // mirrored with Terminal.app via opus-attach.
        if tabIdx == 0 && pane.wrapper == nil { return }

        pane.terminate()

        let view = pane.terminal
        let parent = view.superview
        // Order matters: drop from arranged list first (NSSplitView keeps its
        // internal constraints in sync), then detach from the view hierarchy,
        // then redistribute remaining panes evenly.
        if let parentSplit = parent as? NSSplitView {
            parentSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
            parentSplit.adjustSubviews()
        } else {
            view.removeFromSuperview()
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
                window?.makeFirstResponder(tabPanes[tabIdx][newIdx].terminal)
            }
            refreshActiveTabTitle()
        }
    }

    func splitActivePane(vertical: Bool) {
        guard let oldPane = activePane,
              tabPanes.indices.contains(activeTabIndex) else { return }

        let oldView = oldPane.terminal
        let parent = oldView.superview
        // Inherit oldView's frame so the new pane never starts at zero size —
        // NSSplitView would briefly hand a 0×0 child to SwiftTerm otherwise,
        // and its size-change calc can produce negative cols/rows during that
        // first layout pass (which is what makes the UInt16 conversion crash).
        let newPane = TabPane.makePrivate(frame: oldView.frame, panel: nil, container: self)
        styleTerminal(newPane.terminal)
        newPane.start()

        if let parentSplit = parent as? NSSplitView, parentSplit.isVertical == vertical {
            // Same axis — extend the existing split.
            let idx = (parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0) + 1
            parentSplit.insertArrangedSubview(newPane.terminal, at: idx)
            parentSplit.adjustSubviews()
        } else if let parentSplit = parent as? NSSplitView {
            // Different axis — wrap old pane in a perpendicular split. NSSplitView
            // doesn't auto-redistribute when we remove and re-insert: removing
            // newPane1 lets sharedTerminal stretch to full width, then the inner
            // gets 0 width on insertion (looks like "Cmd+Shift+D cancelled Cmd+D").
            // adjustSubviews() forces an even split again.
            let idx = parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0
            parentSplit.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
            let inner = OpusSplitView(frame: oldView.frame)
            inner.isVertical = vertical
            inner.addArrangedSubview(oldView)
            inner.addArrangedSubview(newPane.terminal)
            parentSplit.insertArrangedSubview(inner, at: idx)
            parentSplit.adjustSubviews()
            inner.adjustSubviews()
        } else {
            // Old view is the tab's top-level — promote it inside a new NSSplitView.
            let root = OpusSplitView(frame: oldView.frame)
            root.isVertical = vertical
            root.autoresizingMask = oldView.autoresizingMask
            oldView.removeFromSuperview()
            root.addArrangedSubview(oldView)
            root.addArrangedSubview(newPane.terminal)
            terminalArea.addSubview(root)
            tabs[activeTabIndex] = root
            root.adjustSubviews()
        }

        tabPanes[activeTabIndex].append(newPane)
        tabActivePaneIndex[activeTabIndex] = tabPanes[activeTabIndex].count - 1
        window?.makeFirstResponder(newPane.terminal)
        refreshActiveTabTitle()
    }

    func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else { return }

        // Before we leave the current tab, remember which pane has focus so we
        // can restore it next time the user comes back.
        let prev = activeTabIndex
        if tabPanes.indices.contains(prev),
           let fr = window?.firstResponder as? TerminalView,
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
        window?.makeFirstResponder(pane.terminal)

        // Shared pane → push its dimensions back to the broadcast PTY.
        if pane.wrapper == nil {
            ClaudeBackend.shared.setPrimarySize(
                cols: UInt16(pane.terminal.getTerminal().cols),
                rows: UInt16(pane.terminal.getTerminal().rows)
            )
        }
    }

    func copySelectionToPasteboard() {
        guard let terminal = activeTerminal else { return }
        let selection = terminal.getSelection()
        guard let text = selection, !text.isEmpty else {
            let interrupt = ArraySlice<UInt8>([0x03])
            if let wrapper = activePane?.wrapper {
                wrapper.sendInput(bytes: interrupt)
            } else {
                ClaudeBackend.shared.send(data: interrupt)
            }
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteFromPasteboard() {
        guard let pane = activePane,
              let str = NSPasteboard.general.string(forType: .string),
              !str.isEmpty else { return }
        let bytes = ArraySlice(Array(str.utf8))
        if let wrapper = pane.wrapper {
            wrapper.sendInput(bytes: bytes)
        } else {
            ClaudeBackend.shared.send(data: bytes)
        }
    }

    func refreshActiveTabTitle() {
        guard tabPanes.indices.contains(activeTabIndex),
              tabActivePaneIndex.indices.contains(activeTabIndex) else { return }
        let idx = tabActivePaneIndex[activeTabIndex]
        let panes = tabPanes[activeTabIndex]
        guard panes.indices.contains(idx) else { return }
        tabTitles[activeTabIndex] = panes[idx].title
        tabBar.titles = tabTitles
    }

    func updateTabIndicator() {
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
        layoutSubtreeIfNeeded()
    }

    func handlePrivateTabTerminated(_ wrapper: FilteredClaudeTab) {
        // Don't auto-close the pane — show the dead-session overlay instead.
        // The user picks between "Start new session" (restart claude in-place)
        // and "Close Opus" (quit the app entirely).
        for paneList in tabPanes {
            if let pane = paneList.first(where: { $0.wrapper === wrapper }) {
                showDeadOverlay(forPane: pane, isShared: false)
                return
            }
        }
    }

    // MARK: Dead-pane overlay

    /// Keyed by the pane's terminal view (object identity). Holds the overlay
    /// NSView so we can remove it again on restart.
    private var deadOverlays: [ObjectIdentifier: NSView] = [:]

    @objc fileprivate func sharedBackendDidTerminate(_ note: Notification) {
        // Show overlay on tab 0's shared pane (the one with no FilteredClaudeTab wrapper).
        guard useSharedTab0,
              tabPanes.indices.contains(0),
              let pane = tabPanes[0].first(where: { $0.wrapper == nil }) else { return }
        showDeadOverlay(forPane: pane, isShared: true)
    }

    private func showDeadOverlay(forPane pane: TabPane, isShared: Bool) {
        let id = ObjectIdentifier(pane.terminal)
        if deadOverlays[id] != nil { return }   // already up

        let overlay = NSView(frame: pane.terminal.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor

        let title = NSTextField(labelWithString: "Session ended")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        title.textColor = NSColor(red: 0.96, green: 0.91, blue: 0.82, alpha: 1.0)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString:
            isShared
                ? "The shared Claude session exited."
                : "Claude exited in this tab."
        )
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 0.65)
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let restartBtn = NSButton(
            title: "Start new session",
            target: self,
            action: isShared ? #selector(restartSharedFromOverlay(_:))
                             : #selector(restartPrivateFromOverlay(_:))
        )
        restartBtn.bezelStyle = .rounded
        restartBtn.keyEquivalent = "\r"   // Return key activates
        restartBtn.translatesAutoresizingMaskIntoConstraints = false

        let closeBtn = NSButton(
            title: "Close Opus",
            target: self,
            action: #selector(quitOpusFromOverlay)
        )
        closeBtn.bezelStyle = .rounded
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        for v in [title, subtitle, restartBtn, closeBtn] {
            overlay.addSubview(v)
        }

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -48),
            subtitle.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            restartBtn.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            restartBtn.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 20),
            restartBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            closeBtn.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            closeBtn.topAnchor.constraint(equalTo: restartBtn.bottomAnchor, constant: 8),
            closeBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])

        pane.terminal.addSubview(overlay)
        deadOverlays[id] = overlay
    }

    private func hideDeadOverlay(forPane pane: TabPane) {
        let id = ObjectIdentifier(pane.terminal)
        deadOverlays[id]?.removeFromSuperview()
        deadOverlays.removeValue(forKey: id)
        // Clear the terminal's screen so old (dead) output doesn't bleed into
        // the fresh session's render. ESC c is the full reset escape.
        pane.terminal.feed(text: "\u{001B}c")
    }

    @objc private func restartSharedFromOverlay(_ sender: NSButton) {
        ClaudeBackend.shared.startIfNeeded()
        guard tabPanes.indices.contains(0),
              let pane = tabPanes[0].first(where: { $0.wrapper == nil }) else { return }
        hideDeadOverlay(forPane: pane)
    }

    @objc private func restartPrivateFromOverlay(_ sender: NSButton) {
        // Walk up: button → overlay → terminal → find the matching pane.
        guard let overlay = sender.superview,
              let terminal = overlay.superview as? TerminalView else { return }
        for paneList in tabPanes {
            if let pane = paneList.first(where: { $0.terminal === terminal }),
               let wrapper = pane.wrapper {
                hideDeadOverlay(forPane: pane)
                wrapper.restart()
                return
            }
        }
    }

    @objc private func quitOpusFromOverlay() {
        NSApp.terminate(nil)
    }

    func updatePrivateTabTitle(_ wrapper: FilteredClaudeTab) {
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

    private func terminalFrame() -> NSRect { terminalArea.bounds }

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

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        ClaudeBackend.shared.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        ClaudeBackend.shared.setPrimarySize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
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
}
