// SpawnEnvironment — the environment handed to every spawned shell session.
//
// Why this exists: SwiftTerm's `startProcess(environment: nil)` default builds
// a minimal env (TERM/COLORTERM/LANG/USER/HOME) that deliberately OMITS PATH.
// zsh then falls back to its compiled-in default — until a ~/.zshenv rebuilds
// PATH from scratch (Homebrew's `brew shellenv` does exactly that when PATH is
// empty), leaving the child with no /usr/bin:/bin. Claude Code stores OAuth
// credentials in the macOS Keychain via `security` (/usr/bin) — with that PATH
// it silently reports "Not logged in" and /login can never persist. bash-based
// hooks die too (2026-08-10 login bug).
//
// The rule real terminals follow: inherit the app's full environment (a Dock
// launch already carries the system PATH baseline), force the terminal
// identity vars, and guarantee the four system directories are on PATH no
// matter what login files later do to it.

import Foundation

enum SpawnEnvironment {
    /// Directories that must survive any dotfile PATH surgery.
    static let systemPathEntries = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Claude Code stamps its child processes with session markers. If Opus
    /// itself was launched from inside a Claude Code session (open(1) leaks
    /// the caller's environment through LaunchServices), an inherited marker
    /// makes the spawned claude believe it is a nested child session and it
    /// disables transcript persistence — silently breaking --resume. Strip
    /// the runtime markers; deliberate user CONFIG vars (e.g.
    /// CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION) pass through.
    static let claudeSessionMarkers = [
        "CLAUDECODE",
        "CLAUDE_CODE_CHILD_SESSION",
        "CLAUDE_CODE_SESSION_ID",
        "CLAUDE_CODE_ENTRYPOINT",
        "CLAUDE_CODE_SSE_PORT",
        "CLAUDE_CODE_MESSAGING_SOCKET",
        "CLAUDE_CODE_BRIDGE_SESSION_ID",
        "CLAUDE_CODE_EXECPATH",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
    ]

    /// Build the child environment in SwiftTerm's "KEY=VALUE" format.
    /// `base` defaults to the app's own environment; injectable for tests.
    static func make(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var env = base
        for marker in claudeSessionMarkers {
            env.removeValue(forKey: marker)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if (env["LANG"] ?? "").isEmpty {
            env["LANG"] = "en_US.UTF-8"
        }
        env["PATH"] = ensureSystemPath(env["PATH"])
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Append any missing system directory to a (possibly empty) PATH,
    /// preserving the existing order so user prefixes keep priority.
    static func ensureSystemPath(_ path: String?) -> String {
        var entries = (path ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        for dir in systemPathEntries where !entries.contains(dir) {
            entries.append(dir)
        }
        return entries.joined(separator: ":")
    }
}
