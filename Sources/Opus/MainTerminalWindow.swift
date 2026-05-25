// MainTerminalWindow — standalone NSWindow hosting a TerminalContainerView.
// For users who prefer all terminals in one persistent window rather than
// the slide-down panel. Has its own private tab 0 (does NOT share the
// ClaudeBackend broadcast with Terminal.app — that's the panel's job).

import AppKit

final class MainTerminalWindow: NSWindowController, TerminalContainerHost {
    static let shared = MainTerminalWindow()

    private var container: TerminalContainerView!
    private var keyMonitor: Any?

    private convenience init() {
        let initial = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let win = NSWindow(
            contentRect: initial,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Opus — Main"
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
        let cont = TerminalContainerView(frame: content.bounds, useSharedTab0: false)
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

    private func handleKey(_ ev: NSEvent) -> NSEvent? {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods == .command, let c = ev.charactersIgnoringModifiers?.lowercased() {
            switch c {
            case "t": container.spawnNewTab(); return nil
            case "w": container.closeActivePane(); return nil
            case "d": container.splitActivePane(vertical: true); return nil
            case "c": container.copySelectionToPasteboard(); return nil
            case "v": container.pasteFromPasteboard(); return nil
            default: break
            }
            if let tabIdx = Self.kc_Digits[ev.keyCode] {
                container.switchTab(to: tabIdx)
                return nil
            }
        }
        if mods == [.command, .shift], ev.charactersIgnoringModifiers?.lowercased() == "d" {
            container.splitActivePane(vertical: false); return nil
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
    }

    func toggle() {
        if window?.isVisible == true {
            window?.orderOut(nil)
        } else {
            show()
        }
    }
}
