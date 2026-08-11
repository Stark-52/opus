// MainTerminalWindow — standalone NSWindow hosting a TerminalContainerView.
// For users who prefer all terminals in one persistent window rather than
// the slide-down panel. Has its own private tab 0 (does NOT share the
// ClaudeBackend broadcast with Terminal.app — that's the panel's job).

import AppKit

final class MainTerminalWindow: NSWindowController, TerminalContainerHost {
    static let shared = MainTerminalWindow()

    private var container: TerminalContainerView!
    var terminalContainer: TerminalContainerView { container }
    private var keyMonitor: Any?

    private convenience init() {
        let initial = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let win = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Opus - Main"
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("OpusMainWindow")  // persists frame across launches
        win.collectionBehavior = [.fullScreenPrimary]
        self.init(window: win)
        setupContent()
        installKeyMonitor()
    }

    private func setupContent() {
        guard let win = window, let content = win.contentView else { return }
        // useSharedTab0: true → main window's tab 0 subscribes to the same
        // ClaudeBackend broadcast as the panel and Terminal.app. Typing in any
        // surface shows in every surface. Cmd+T spawns private tabs as before.
        let cont = TerminalContainerView(frame: content.bounds, useSharedTab0: true)
        cont.host = self
        cont.autoresizingMask = [.width, .height]
        content.addSubview(cont)
        self.container = cont
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self, ev.window === self.window else { return ev }
            return self.handleKey(ev) ?? ev
        }
    }

    /// Cmd-key chars that must fall through to the find bar's field editor
    /// (instead of acting on the live session) while it has focus. F/G are
    /// deliberately excluded — they're meant to work FROM the field. Kept
    /// in sync with QuickTerminalPanel.findBarBypassChars.
    private static let findBarBypassChars: Set<String> = ["c", "v", "t", "w", "d", ","]

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = KeyMods.shortcutMods(ev.modifierFlags)
        if mods == .command {
            if let c = ev.charactersIgnoringModifiers?.lowercased() {
                // See QuickTerminalPanel.handleKeyEvent for the full rationale:
                // Cmd+V into a focused find-bar field must not paste into the
                // live claude prompt, Cmd+C there must not send an interrupt.
                if container.findBarHasFocus, Self.findBarBypassChars.contains(c) { return ev }
                switch c {
                case "t": container.spawnNewTab(); return nil
                case "w": container.closeActivePane(); return nil
                case "d": container.splitActivePane(vertical: true); return nil
                case "c": container.copySelectionToPasteboard(); return nil
                case "v": container.pasteFromPasteboard(); return nil
                case ",": SettingsWindowController.shared.show(); return nil
                case "f": container.toggleFindBar(); return nil
                case "g": container.findNextInActivePane(); return nil
                case "k": SessionSwitcherPanel.shared.toggle(); return nil
                default: break
                }
            }
            // Font zoom by physical key: = (24), - (27), 0 (29). AZERTY-safe.
            // Left intercepted even while the find bar has focus — harmless.
            // Prompt jump by arrow key: ↑ (126), ↓ (125). Layout-independent
            // keyCode. Unlike zoom, these must fall through to the find
            // bar's field editor while it has focus — see
            // QuickTerminalPanel.handleKeyEvent for the full rationale.
            if container.findBarHasFocus, ev.keyCode == 126 || ev.keyCode == 125 { return ev }
            switch ev.keyCode {
            case 24: OpusPreferences.shared.bumpFontSize(+1); return nil
            case 27: OpusPreferences.shared.bumpFontSize(-1); return nil
            case 29: OpusPreferences.shared.resetFontSize(); return nil
            case 126: container.jumpToPreviousPrompt(); return nil
            case 125: container.jumpToNextPrompt(); return nil
            default: break
            }
            // Tab-switch digits: pass through while the find bar has focus —
            // see QuickTerminalPanel.handleKeyEvent for the reasoning.
            if container.findBarHasFocus { return ev }
            if let tabIdx = Self.kc_Digits[ev.keyCode] {
                container.switchTab(to: tabIdx)
                return nil
            }
        }
        if mods == [.command, .shift], ev.charactersIgnoringModifiers?.lowercased() == "d" {
            container.splitActivePane(vertical: false); return nil
        }
        if mods == [.command, .shift], ev.charactersIgnoringModifiers?.lowercased() == "g" {
            container.findPreviousInActivePane(); return nil
        }
        // Cmd+Shift+I — toggle broadcast input to every pane of the active
        // tab (Lot 3, Task 7). "I" for Input.
        if mods == [.command, .shift], ev.charactersIgnoringModifiers?.lowercased() == "i" {
            container.toggleBroadcast(); return nil
        }
        return ev
    }

    // AZERTY-safe digit table (matches panel's kc_Digits)
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

    // MARK: TerminalContainerHost

    var hostWindow: NSWindow? { window }
    func openInTerminalRequested() {
        // Main window doesn't mirror with Terminal.app; the panel owns that.
        // Spawning anyway would launch a Terminal that connects to /tmp/opus.sock
        // which (in standalone window-only mode) doesn't exist. No-op for now.
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        // Parity with QuickTerminalPanel.show(): re-summoning this window
        // doesn't go through switchTab, so the active tab's dot needs its
        // own "seen" clear here.
        container.markActiveTabSeen()
    }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            show()
        }
    }
}
