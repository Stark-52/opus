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
    static let claudeBackendDidTerminate = Notification.Name("com.stark52.opus.claudeBackendDidTerminate")
}

/// Posted (on main) when skipPermissionsActive flips — the
/// shield buttons and menu items refresh their checked/orange state from it.
extension Notification.Name {
    static let opusSkipPermissionsChanged = Notification.Name("com.stark52.opus.skipPermissionsChanged")
}

/// Posted (on main) right after a deliberate spawn/respawn so any stale
/// "Session ended" overlay on the shared pane can dismiss itself.
extension Notification.Name {
    static let claudeBackendDidSpawn = Notification.Name("com.stark52.opus.claudeBackendDidSpawn")
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

    /// The session id of the CURRENTLY spawned claude process, when Opus
    /// knows it up front (Lot 3, Task 6). Three cases, decided in `spawn`:
    ///   - fresh spawn (`resumeMode == .none`): Opus mints a UUID, passes it
    ///     as `--session-id`, and stores it here — we KNOW the session
    ///     because we picked its id.
    ///   - `.resume(sessionId:)`: the caller (restart(resume:), the Cmd+K
    ///     session switcher) already knows the exact id — store it as-is.
    ///   - `.continueMostRecent` (`claude --continue`): the id is claude's
    ///     choice, not ours — unknown until the SessionStart hook reports
    ///     it. `nil` here means exactly that; `ClaudeStateStore`'s
    ///     spawn-order FIFO is the fallback for this one case.
    private(set) var currentSessionId: String?

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
    /// (menu Restart / project switch). `currentSessionId` (Lot 3, Task 6) is
    /// the exact id of the conversation this backend is running RIGHT NOW —
    /// when we know it (every case except a `.continueMostRecent` launch), it
    /// is strictly better than re-deriving one from disk: `ClaudeSessionLocator`
    /// picks the most-recently-MODIFIED transcript in the cwd, which with two
    /// or more sessions written close together (or simply an idle one that
    /// hasn't had its mtime bumped in a while) can silently resume the WRONG
    /// conversation. `currentSessionId` can't be wrong — it's literally what
    /// this process was told to be. The locator is kept purely as the
    /// fallback for the one case where we don't know it: after a
    /// `--continue`-launched session (`currentSessionId == nil` — claude, not
    /// Opus, picked that id), locator lookup is the best remaining option.
    func restart(resume: Bool) {
        var mode: OpusResumeMode = .none
        if resume {
            if let id = currentSessionId {
                mode = .resume(sessionId: id)
            } else if let id = ClaudeSessionLocator.mostRecentSessionId(
                for: OpusPreferences.shared.workingDirectory) {
                mode = .resume(sessionId: id)
            } else {
                mode = .continueMostRecent
            }
        }
        restart(mode: mode)
    }

    /// Kill the current claude and spawn a fresh one with a caller-supplied
    /// resume mode — used directly by the session switcher (Cmd+K), which
    /// already knows the exact session ID to resume, and by `restart(resume:)`
    /// above for the derived-from-cwd cases.
    func restart(mode: OpusResumeMode) {
        if isRestarting {
            // A restart is already in flight: the SIGTERM/SIGKILL dance is
            // armed and processTerminated will respawn. Just record the most
            // recent intent — no second signal volley.
            pendingResumeMode = mode
            return
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
        // Decide currentSessionId BEFORE building the command — resolvedSpawnCommand
        // needs it for the .none case, and every other spawn effect (the
        // claudeBackendDidSpawn notification below) reads it after this point.
        switch resumeMode {
        case .none:
            currentSessionId = UUID().uuidString.lowercased()
        case .resume(let id):
            currentSessionId = id
        case .continueMostRecent:
            currentSessionId = nil
        }
        // -l -i runs a login+interactive shell like a real terminal would:
        // /etc/zprofile (path_helper) restores the system PATH baseline and
        // .zshrc adds ~/.local/bin where claude lives.
        // `command claude` bypasses any shell function/alias a user's .zshrc
        // might define for the name `claude` — e.g. if the optional
        // `claude-join` wrapper documented in the README were named `claude`
        // instead, this avoids spawning it recursively.
        // Bench mode: if /tmp/opus_bench_active exists, cat the bench file and
        // capture timing instead of launching claude — used for the rendering
        // benchmark vs Ghostty.
        let cmd: String
        if FileManager.default.fileExists(atPath: "/tmp/opus_bench_active") {
            cmd = "{ time cat /tmp/opus_bench.txt ; } 2> /tmp/opus_render_time.txt; touch /tmp/opus_bench_done"
        } else {
            cmd = OpusPreferences.shared.resolvedSpawnCommand(
                skipPermissions: skipPermissionsActive,
                resumeMode: resumeMode,
                sessionId: currentSessionId
            )
        }
        p.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-i", "-c", cmd],
            environment: SpawnEnvironment.make(),
            execName: nil
        )
        // forkpty can fail (fd exhaustion, jetsam pressure). SwiftTerm leaves
        // shellPid at 0 and will never call processTerminated — clear our
        // reference so startIfNeeded/restart aren't wedged forever, and surface
        // the dead-session overlay instead of a silent black pane.
        if p.shellPid <= 0 {
            NSLog("ClaudeBackend: spawn failed (forkpty returned no pid)")
            process = nil
            isRestarting = false
            // No process ever actually ran with the id we just minted/knew —
            // clear it so a later restart(resume:) doesn't "resume" a
            // conversation that never started.
            currentSessionId = nil
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .claudeBackendDidTerminate,
                    object: nil,
                    userInfo: ["exitCode": -1]
                )
            }
            return
        }
        DispatchQueue.main.async {
            // Cockpit (Lot 3, Task 6): carry the known session id (nil after a
            // --continue launch) so the shared-pane container(s) can bind
            // tab 0's pane token directly instead of waiting on the
            // spawn-order FIFO heuristic — see ClaudeStateStore.bindSession
            // and TerminalContainerView.sharedBackendDidSpawn.
            var userInfo: [String: Any] = [:]
            if let id = self.currentSessionId { userInfo["sessionId"] = id }
            NotificationCenter.default.post(name: .claudeBackendDidSpawn, object: nil, userInfo: userInfo)
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
