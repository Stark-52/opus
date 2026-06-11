// ClaudeBackend — owns a single claude process via SwiftTerm's LocalProcess
// (PTY-managed shell). Multiple subscribers can read its output and send input.
// Each subscriber represents a client (panel today; Unix-socket attaches in
// Phase 2). This is the foundation for the custom multiplexer that will
// eventually re-render per client to eliminate the size-mismatch distortion
// dtach can't fix.

import Foundation
import Darwin
import SwiftTerm

/// Posted (on main) when the underlying claude process exits — the dead-pane
/// overlay listens for this to surface a Start-new-session / Close-Opus UI.
extension Notification.Name {
    static let claudeBackendDidTerminate = Notification.Name("com.andygarcia.opus.claudeBackendDidTerminate")
}

/// Posted (on main) when skipPermissionsActive flips — the
/// shield buttons and menu items refresh their checked/orange state from it.
extension Notification.Name {
    static let opusSkipPermissionsChanged = Notification.Name("com.andygarcia.opus.skipPermissionsChanged")
}

/// Posted (on main) right after a deliberate spawn/respawn so any stale
/// "Session ended" overlay on the shared pane can dismiss itself.
extension Notification.Name {
    static let claudeBackendDidSpawn = Notification.Name("com.andygarcia.opus.claudeBackendDidSpawn")
}

final class ClaudeBackend: NSObject, LocalProcessDelegate {
    static let shared = ClaudeBackend()

    private var process: LocalProcess?
    private var subscribers: [UUID: (ArraySlice<UInt8>) -> Void] = [:]
    private var primarySize: winsize = winsize(ws_row: 40, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)

    /// Per-app-run permission mode for the shared session (new private tabs
    /// inherit it too). Seeded from the Settings default; flipped live by the
    /// shield button / menu toggle.
    /// Seeded lazily (first access happens in spawn, after init) so the two
    /// singletons' initializers can never form a swift_once re-entrancy cycle.
    private(set) lazy var skipPermissionsActive = OpusPreferences.shared.skipPermissions

    /// True while a deliberate restart is in flight — suppresses the
    /// dead-session overlay and makes processTerminated respawn instead.
    private var isRestarting = false
    private var pendingResumeMode: OpusResumeMode = .none

    /// Spawn claude (idempotent — does nothing if already running).
    func startIfNeeded() {
        guard process == nil else { return }
        let resume: OpusResumeMode =
            OpusPreferences.shared.resumeLastConversation ? .continueMostRecent : .none
        spawn(resumeMode: resume)
    }

    /// Flip dangerous mode and bounce the session back into the SAME
    /// conversation (resume by session ID, --continue fallback).
    func toggleSkipPermissions() {
        skipPermissionsActive.toggle()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .opusSkipPermissionsChanged, object: nil)
        }
        restart(resume: true)
    }

    /// Kill the current claude and spawn a fresh one. `resume: true` reopens
    /// the same conversation (dangerous-mode toggle); `false` starts clean
    /// (menu Restart / project switch).
    func restart(resume: Bool) {
        var mode: OpusResumeMode = .none
        if resume {
            if let id = ClaudeSessionLocator.mostRecentSessionId(
                for: OpusPreferences.shared.workingDirectory) {
                mode = .resume(sessionId: id)
            } else {
                mode = .continueMostRecent
            }
        }
        guard let p = process, p.shellPid > 0 else {
            // Nothing running (dead-overlay state) — just spawn.
            spawn(resumeMode: mode)
            return
        }
        pendingResumeMode = mode
        isRestarting = true
        kill(p.shellPid, SIGTERM)
        // Escalate if claude ignores SIGTERM (wedged TUI): SIGKILL after 1.5s.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRestarting,
                  let p = self.process, p.shellPid > 0 else { return }
            kill(p.shellPid, SIGKILL)
        }
    }

    private func spawn(resumeMode: OpusResumeMode) {
        guard process == nil else { return }
        let p = LocalProcess(delegate: self)
        process = p
        // -i sources .zshrc so PATH includes ~/.local/bin where claude lives.
        // `command claude` skips the .zshrc wrapper to avoid recursion.
        // Bench mode: if /tmp/opus_bench_active exists, cat the bench file and
        // capture timing instead of launching claude — used for the rendering
        // benchmark vs Ghostty.
        let cmd: String
        if FileManager.default.fileExists(atPath: "/tmp/opus_bench_active") {
            cmd = "{ time cat /tmp/opus_bench.txt ; } 2> /tmp/opus_render_time.txt; touch /tmp/opus_bench_done"
        } else {
            cmd = OpusPreferences.shared.resolvedSpawnCommand(
                skipPermissions: skipPermissionsActive,
                resumeMode: resumeMode
            )
        }
        p.startProcess(
            executable: "/bin/zsh",
            args: ["-i", "-c", cmd],
            environment: nil,
            execName: nil
        )
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .claudeBackendDidSpawn, object: nil)
        }
    }

    /// Add a data subscriber. Returns a token used to unsubscribe.
    /// The subscribers dict is only ever touched on the main queue —
    /// SocketServer calls this from its accept/read queues, so hop if needed.
    @discardableResult
    func subscribe(_ handler: @escaping (ArraySlice<UInt8>) -> Void) -> UUID {
        let token = UUID()
        onMain { self.subscribers[token] = handler }
        return token
    }

    func unsubscribe(_ token: UUID) {
        onMain { self.subscribers.removeValue(forKey: token) }
    }

    /// Run on main — synchronously when already there (preserves the historic
    /// "subscribed before this call returns" behavior for main-thread callers).
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    /// Send input bytes to claude (from any client).
    func send(data: ArraySlice<UInt8>) {
        process?.send(data: data)
    }

    /// Update claude's PTY size. We ioctl the master FD directly (accessed via
    /// reflection on SwiftTerm's LocalProcess.childfd since it's not public),
    /// then SIGWINCH claude so it re-reads the size and redraws. Used for
    /// focus-following resize: when panel takes focus, resize to panel; when
    /// Terminal.app takes focus, resize to Terminal.app.
    func setPrimarySize(cols: UInt16, rows: UInt16) {
        primarySize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard let p = process else { return }
        let mirror = Mirror(reflecting: p)
        for child in mirror.children where child.label == "childfd" {
            if let fd = child.value as? Int32, fd >= 0 {
                var ws = primarySize
                _ = ioctl(fd, TIOCSWINSZ, &ws)
            }
        }
        if p.shellPid > 0 {
            kill(p.shellPid, SIGWINCH)
        }
    }

    // MARK: LocalProcessDelegate

    func dataReceived(slice: ArraySlice<UInt8>) {
        // Broadcast to all subscribers on main queue (so view updates are safe).
        let snapshot = subscribers.values
        DispatchQueue.main.async {
            for handler in snapshot { handler(slice) }
        }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        NSLog("ClaudeBackend: claude terminated (exit=\(exitCode ?? -1))")
        process = nil
        if isRestarting {
            isRestarting = false
            let mode = pendingResumeMode
            pendingResumeMode = .none
            DispatchQueue.main.async {
                // Clear every surface so the dead TUI doesn't bleed into the
                // fresh session — ESC c is the full terminal reset. (It passes
                // the cursor-visibility filter untouched; socket clients get
                // the raw bytes and Terminal.app resets too.)
                let reset = ArraySlice(Array("\u{001B}c".utf8))
                for handler in self.subscribers.values { handler(reset) }
                self.spawn(resumeMode: mode)
            }
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .claudeBackendDidTerminate,
                object: nil,
                userInfo: ["exitCode": exitCode ?? -1]
            )
        }
    }

    func getWindowSize() -> winsize {
        return primarySize
    }
}
