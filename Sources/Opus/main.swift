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
final class OpusTabBar: NSView {
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
final class FilteredClaudeTab: NSObject, LocalProcessDelegate, TerminalViewDelegate {
    let terminal: TerminalView
    private var process: LocalProcess!
    weak var panel: QuickTerminalPanel?
    weak var container: TerminalContainerView?
    var title: String = "Claude"

    init(frame: NSRect, panel: QuickTerminalPanel?, container: TerminalContainerView?) {
        self.terminal = TerminalView(frame: frame)
        self.panel = panel
        self.container = container
        super.init()
        self.process = LocalProcess(delegate: self)
        self.terminal.terminalDelegate = self
    }

    func start() {
        // Private tabs inherit the live dangerous-mode state but NEVER resume:
        // --continue here would attach the same transcript as tab 0 (two
        // claudes writing one session file).
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-i", "-c", OpusPreferences.shared.resolvedSpawnCommand(
                skipPermissions: ClaudeBackend.shared.skipPermissionsActive,
                resumeMode: .none)],
            environment: nil,
            execName: nil
        )
    }

    /// SIGHUP claude so it cleans up TUI state and exits before we drop the pane.
    func terminate() {
        if process?.shellPid ?? 0 > 0 { kill(process.shellPid, SIGHUP) }
    }

    /// Recreate the LocalProcess and respawn the configured command. Used by the
    /// dead-pane overlay's "Start new session" button after the previous process
    /// exited and we left the pane visible instead of closing it.
    func restart() {
        self.process = LocalProcess(delegate: self)
        start()
    }

    /// Inject bytes into this pane's PTY process. Used by `QuickTerminalPanel.pasteFromPasteboard`
    /// and `QuickTerminalPanel.copySelectionToPasteboard` (and the equivalent
    /// methods on `TerminalContainerView`) when the active pane is private
    /// (has its own `LocalProcess`). Default-internal so the new container can call it.
    func sendInput(bytes: ArraySlice<UInt8>) {
        process.send(data: bytes)
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
            // panel host now also routes through container — see Task 13.
            self.container?.handlePrivateTabTerminated(self)
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
        // panel host now also routes through container — see Task 13.
        container?.updatePrivateTabTitle(self)
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
final class TabPane {
    let terminal: TerminalView
    let wrapper: FilteredClaudeTab?            // non-nil → private claude
    fileprivate var sharedSubscription: UUID?  // non-nil → shared backend
    var title: String = "Claude"

    static func makeShared(frame: NSRect, panel: QuickTerminalPanel?, container: TerminalContainerView?) -> TabPane {
        let pane = TabPane(frame: frame, wrapper: nil)
        pane.terminal.terminalDelegate = container
        pane.sharedSubscription = ClaudeBackend.shared.subscribe { [weak pane] slice in
            let filtered = QuickTerminalPanel.stripCursorVisibilityToggles(slice)
            pane?.terminal.feed(byteArray: filtered[...])
        }
        return pane
    }

    static func makePrivate(frame: NSRect, panel: QuickTerminalPanel?, container: TerminalContainerView?) -> TabPane {
        let wrapper = FilteredClaudeTab(frame: frame, panel: panel, container: container)
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

// NSSplitView with our own divider — wider and tinted with the panel's accent
// color (same soft blue as the active tab pill) so splits read clearly against
// the dark blur background. The system's default thin gray divider blends in
// too much to tell where one pane ends and the next begins.
final class OpusSplitView: NSSplitView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        dividerStyle = .thin
    }

    override var dividerThickness: CGFloat { 2 }
    override var dividerColor: NSColor {
        // Pale icy-cyan — the Opus icon's core glow color. Low alpha keeps it
        // subtle against the dark blur so the pane content stays the focus.
        NSColor(red: 0.60, green: 0.85, blue: 0.95, alpha: 0.30)
    }
    override func drawDivider(in rect: NSRect) {
        dividerColor.setFill()
        rect.fill()
    }
}

// MARK: - Persisted panel geometry

/// UserDefaults keys for panel size persistence. Keyed by screen size so a
/// resize on the laptop display doesn't dictate the panel size on a 34" UWQHD.
private enum PanelGeometryDefaults {
    static func key(forScreen screen: NSScreen) -> String {
        // Prefer the CGDirectDisplayID (unique per physical connector, stable across
        // reboots) so two identical monitors don't share one saved geometry.
        // Fallback to size-based key if the display number is somehow unavailable.
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int) ?? 0
        if displayID != 0 {
            return "opus.panelGeometry.display\(displayID)"
        }
        let f = screen.frame
        return "opus.panelGeometry.\(Int(f.width))x\(Int(f.height))"
    }
    static func read(forScreen screen: NSScreen) -> (width: CGFloat, height: CGFloat)? {
        let d = UserDefaults.standard.dictionary(forKey: key(forScreen: screen))
        guard let w = d?["width"] as? Double,
              let h = d?["height"] as? Double,
              w > 200, h > 100 else { return nil }
        return (CGFloat(w), CGFloat(h))
    }
    static func write(forScreen screen: NSScreen, width: CGFloat, height: CGFloat) {
        UserDefaults.standard.set(
            ["width": Double(width), "height": Double(height)],
            forKey: key(forScreen: screen)
        )
    }
}

final class QuickTerminalPanel: NSObject {
    private let panel: OpusPanel
    private var blurView: NSVisualEffectView!
    private var tintView: NSView!
    private var imageBgView: NSImageView!
    private var container: TerminalContainerView!
    private var keyMonitor: Any?
    private var visible = false
    private var suppressResizeSave = false

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
        // Background image layer (below tint, hidden unless mode == image)
        let bg = NSImageView(frame: blur.bounds)
        bg.imageScaling = .scaleAxesIndependently
        bg.autoresizingMask = [.width, .height]
        bg.isHidden = true
        blur.addSubview(bg)
        imageBgView = bg

        let tint = NSView(frame: blur.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        tintView = tint
        panel.contentView = blur
        blurView = blur

        // "Open in Terminal" button — top-right of the blur. Spawns a fresh
        // Terminal.app window joining the shared claude session via opus-attach.
        let openBtn = NSButton(title: "↗", target: self, action: #selector(openInTerminalTapped))
        openBtn.isBordered = false
        openBtn.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        openBtn.contentTintColor = NSColor(red: 0.93, green: 0.92, blue: 0.86, alpha: 0.75)
        openBtn.toolTip = "Open a Terminal.app window mirroring the shared session"
        openBtn.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(openBtn)
        NSLayoutConstraint.activate([
            openBtn.topAnchor.constraint(equalTo: blur.topAnchor, constant: 6),
            openBtn.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -10),
            openBtn.widthAnchor.constraint(equalToConstant: 24),
            openBtn.heightAnchor.constraint(equalToConstant: 22)
        ])
        // The ↗ button spawns a Terminal.app window — only meaningful when the
        // current displayMode includes the native Terminal surface.
        openBtn.isHidden = !OpusPreferences.shared.displayMode.includesNativeTerminal

        // Force layout so the blur has its initial bounds before we add the container.
        blur.layoutSubtreeIfNeeded()

        // Container hosts all tabs, panes, splits, tab bar, TerminalViewDelegate.
        let contentBounds = blur.bounds
        let containerFrame = NSRect(
            x: 14, y: 14,
            width: contentBounds.width - 28,
            height: contentBounds.height - 28
        )
        let cont = TerminalContainerView(frame: containerFrame, useSharedTab0: true)
        cont.host = self
        cont.autoresizingMask = [.width, .height]
        blur.addSubview(cont)
        self.container = cont

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(panelDidResize),
            name: NSWindow.didResizeNotification, object: panel
        )
        applyAppearance()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onPreferencesChanged),
            name: .opusPreferencesDidChange, object: nil
        )
    }

    private var ignoreResignKeyUntil: Date?

    @objc private func spaceDidChange() {
        // Give ourselves a 600ms grace period — Space-transition resigns key
        // briefly, but the panel should remain visible on the new Space.
        ignoreResignKeyUntil = Date().addingTimeInterval(0.6)
    }

    @objc private func panelDidResize() {
        // Suppress save during programmatic setFrame() in show() — see show() body
        // for where the flag is toggled. Without this, the very first restore would
        // overwrite the saved size with itself (harmless) AND fire before the user
        // has done anything (also harmless, but pointless writes are noise).
        guard !suppressResizeSave else { return }
        let screen = panel.screen ?? activeScreen()
        PanelGeometryDefaults.write(
            forScreen: screen,
            width: panel.frame.width,
            height: panel.frame.height
        )
    }

    @objc private func openInTerminalTapped() {
        AppDelegate.shared?.launchTerminalSession()
    }

    @objc private func panelDidBecomeKey() {
        // Push the active pane's dimensions to claude — meaningful only if the
        // active pane is the shared one (no wrapper), since private panes own
        // their own PTYs and handle resize through their TerminalViewDelegate.
        guard let pane = container.activePane, pane.wrapper == nil else { return }
        let t = pane.terminal.getTerminal()
        ClaudeBackend.shared.setPrimarySize(cols: UInt16(t.cols), rows: UInt16(t.rows))
    }

    @objc private func onPreferencesChanged() {
        applyAppearance()
    }

    private func applyAppearance() {
        let mode = OpusPreferences.shared.appearanceMode
        switch mode {
        case "transparent":
            blurView.state = .inactive
            tintView.layer?.backgroundColor = NSColor.clear.cgColor
            imageBgView.isHidden = true
        case "tint":
            blurView.state = .active
            let rgba = OpusPreferences.shared.appearanceTintRGBA
            tintView.layer?.backgroundColor = NSColor(
                red: CGFloat(rgba[0]), green: CGFloat(rgba[1]),
                blue: CGFloat(rgba[2]), alpha: CGFloat(rgba[3])
            ).cgColor
            imageBgView.isHidden = true
        case "image":
            blurView.state = .inactive
            // Image needs a floor on the tint so terminal text stays readable.
            tintView.layer?.backgroundColor = NSColor(white: 0, alpha: 0.25).cgColor
            if let path = OpusPreferences.shared.appearanceImagePath,
               let img = NSImage(contentsOfFile: path) {
                imageBgView.image = img
                imageBgView.isHidden = false
            } else {
                imageBgView.isHidden = true
            }
        default:
            // "default" — blur + dark tint at the original RGBA.
            blurView.state = .active
            tintView.layer?.backgroundColor = NSColor(
                red: 0.04, green: 0.05, blue: 0.07, alpha: 0.55
            ).cgColor
            imageBgView.isHidden = true
        }
    }

    // Removes DECTCEM cursor hide (`\e[?25l`) and show (`\e[?25h`) sequences
    // from the byte stream. Claude code emits hide when entering its TUI; if
    // SwiftTerm processes that, the caret disappears inside the panel even
    // though the user is still typing into it. We strip both directions so the
    // caret state stays at SwiftTerm's "visible" default. Only the 6-byte
    // standalone form is matched — claude's TUI lib emits these as separate
    // sequences, not multi-param. If a future version chains them with `;`
    // params, extend this to parse the param list.
    static func stripCursorVisibilityToggles(_ slice: ArraySlice<UInt8>) -> [UInt8] {
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

    // MARK: Key handling

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
                case "t": container.spawnNewTab(); return nil
                case "w": container.closeActivePane(); return nil
                case "d": container.splitActivePane(vertical: true); return nil   // side-by-side (iTerm2 convention)
                case "c": container.copySelectionToPasteboard(); return nil
                case "v": container.pasteFromPasteboard(); return nil
                case ",": SettingsWindowController.shared.show(); return nil
                default: break
                }
            }
            if let tabIdx = Self.kc_Digits[ev.keyCode] {
                container.switchTab(to: tabIdx)
                return nil
            }
        }
        // Cmd+Shift+D — split top/bottom.
        if mods == [.command, .shift],
           ev.charactersIgnoringModifiers?.lowercased() == "d" {
            container.splitActivePane(vertical: false)
            return nil
        }
        return ev
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
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main ?? NSScreen.screens.first!
    }

    private func show() {
        let screen = activeScreen()
        let screenFrame = screen.visibleFrame
        let saved = PanelGeometryDefaults.read(forScreen: screen)
        let w = saved?.width ?? screenFrame.width
        let h = saved?.height ?? screenFrame.height * 0.4
        let frame = screenFrame   // kept for the existing maxY math below

        let target = NSRect(x: frame.origin.x, y: frame.maxY - h, width: w, height: h)

        // Layer-backed content for Core Animation. The panel itself stays at
        // target frame; we animate the content layer's translation to fake the
        // slide (Cocoa's frame animation is unreliable on borderless panels
        // since macOS 14+, so we do CA directly).
        suppressResizeSave = true
        panel.setFrame(target, display: true)
        suppressResizeSave = false  // cleared before any early-return guards below
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
        if let terminal = container.activeTerminal { panel.makeFirstResponder(terminal) }
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

// MARK: - TerminalContainerHost conformance

extension QuickTerminalPanel: TerminalContainerHost {
    var hostWindow: NSWindow? { panel }
    func openInTerminalRequested() {
        AppDelegate.shared?.launchTerminalSession()
    }
}

// MARK: - Carbon hotkey callback

private let hotkeyCallback: EventHandlerUPP = { (_, event, _) -> OSStatus in
    var hkID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject),
                       EventParamType(typeEventHotKeyID),
                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
    DispatchQueue.main.async {
        switch hkID.id {
        case 1: AppDelegate.shared?.toggleNativePanel()
        case 2: MainTerminalWindow.shared.toggle()
        default: break
        }
    }
    return noErr
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyRefMain: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private var nativePanel: QuickTerminalPanel?
    private let socketServer = SocketServer()

    func applicationDidFinishLaunching(_ note: Notification) {
        Self.shared = self

        // Kill any stale dtach/socket leftovers so each launch is fresh.
        killStaleSessionIfOrphaned()

        let display = OpusPreferences.shared.displayMode

        if display.includesNativeTerminal {
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
        }

        installAppMenu()

        if display.includesPanel {
            nativePanel = QuickTerminalPanel()
        }
        if display.includesMain {
            _ = MainTerminalWindow.shared   // instantiates lazily
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                MainTerminalWindow.shared.show()
            }
        }

        registerHotkey()

        if display.includesNativeTerminal {
            launchTerminalSession()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            OnboardingWindowController.shared.showIfNeeded()
        }
        if display.includesPanel {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.nativePanel?.toggle()
            }
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

    // Click the Dock icon: bring something visible to the user. If the panel
    // exists, toggle it; if only the main window exists, show it; if neither,
    // fall back to showing the panel even if it's nil-or-hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let display = OpusPreferences.shared.displayMode
        if display.includesPanel {
            nativePanel?.toggle()
        }
        if display.includesMain {
            MainTerminalWindow.shared.show()
        }
        return true
    }

    // Right-click on the Dock icon: visibility + quit shortcuts. Useful when
    // the user has hidden the panel, closed Terminal.app, and isn't sure how
    // to get back. Cmd+Ctrl+T / Cmd+Ctrl+M still work globally too.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let display = OpusPreferences.shared.displayMode

        if display.includesPanel {
            menu.addItem(NSMenuItem(
                title: "Show Quick Terminal",
                action: #selector(showQuickTerminalAction),
                keyEquivalent: ""
            ))
        }
        if display.includesMain {
            menu.addItem(NSMenuItem(
                title: "Show Main Window",
                action: #selector(showMainWindowAction),
                keyEquivalent: ""
            ))
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Opus",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))
        return menu
    }

    @objc private func showQuickTerminalAction() {
        nativePanel?.toggle()
    }

    @objc private func showMainWindowAction() {
        MainTerminalWindow.shared.show()
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

    fileprivate func launchTerminalSession() {
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
        if let ref = hotKeyRef     { UnregisterEventHotKey(ref) }
        if let ref = hotKeyRefMain { UnregisterEventHotKey(ref) }
        if let ref = handlerRef    { RemoveEventHandler(ref) }
    }

    // MARK: Actions

    func toggleNativePanel() {
        nativePanel?.toggle()
    }

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: Setup

    private func installAppMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(settingsItem)

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Opus",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

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

        if OpusPreferences.shared.displayMode.includesMain {
            let idM = EventHotKeyID(signature: OSType(0x4F505553), id: 2)
            let statusM = RegisterEventHotKey(
                46,                                    // kVK_ANSI_M
                UInt32(cmdKey | controlKey),
                idM, GetApplicationEventTarget(), 0, &hotKeyRefMain
            )
            NSLog("Opus hotkey Cmd+Ctrl+M registered (status=\(statusM))")
        }
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
