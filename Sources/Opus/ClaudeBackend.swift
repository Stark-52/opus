// ClaudeBackend — owns a single claude process via SwiftTerm's LocalProcess
// (PTY-managed shell). Multiple subscribers can read its output and send input.
// Each subscriber represents a client (panel today; Unix-socket attaches in
// Phase 2). This is the foundation for the custom multiplexer that will
// eventually re-render per client to eliminate the size-mismatch distortion
// dtach can't fix.

import Foundation
import Darwin
import SwiftTerm

final class ClaudeBackend: NSObject, LocalProcessDelegate {
    static let shared = ClaudeBackend()

    private var process: LocalProcess?
    private var subscribers: [UUID: (ArraySlice<UInt8>) -> Void] = [:]
    private var primarySize: winsize = winsize(ws_row: 40, ws_col: 200, ws_xpixel: 0, ws_ypixel: 0)

    /// Spawn claude (idempotent — does nothing if already running).
    func startIfNeeded() {
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
            cmd = OpusPreferences.shared.resolvedSpawnCommand()
        }
        p.startProcess(
            executable: "/bin/zsh",
            args: ["-i", "-c", cmd],
            environment: nil,
            execName: nil
        )
    }

    /// Add a data subscriber. Returns a token used to unsubscribe.
    @discardableResult
    func subscribe(_ handler: @escaping (ArraySlice<UInt8>) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
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
    }

    func getWindowSize() -> winsize {
        return primarySize
    }
}
