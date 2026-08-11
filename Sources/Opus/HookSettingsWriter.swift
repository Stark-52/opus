// HookSettingsWriter — generates the --settings JSON Opus injects into every
// spawned `claude` process for the .claude preset (see
// OpusPreferences.composeSpawnCommand). Registers six PURE-OBSERVER command
// hooks: UserPromptSubmit, PreToolUse, PostToolUse, Notification, Stop,
// SessionStart. Each hook is just `opus-attach event <Name>` — it forwards
// claude's own hook stdin verbatim (newline-compacted) to
// /tmp/opus-events.sock and exits 0. See Sources/opus-attach/main.swift's
// `event` subcommand for the write side and EventSocketServer.parse for the
// read side.
//
// --settings MERGES with the user's own ~/.claude/settings.json — both hook
// sets run (see the verified hooks contract, "Hooks from settings files
// merge rather than replace"). These six hooks never write to stdout, never
// exit non-zero, and their `command`/`args` never touch the user's own
// hooks or settings — so this injection cannot suppress, override, or
// interfere with whatever hooks the user already has configured.
//
// Timeout units: the settings-JSON hook timeout is SECONDS (distinct from
// the milliseconds used by Claude Code's own tool-call timeouts).

import Foundation

enum HookSettingsWriter {
    /// The six events Opus observes. `hasMatcher` mirrors the verified
    /// contract: tool events (PreToolUse/PostToolUse) match on `tool_name`
    /// and use "*" for "every tool"; the other four events don't take a
    /// matcher at all. Order here is just the order keys are added before
    /// JSON serialization re-sorts them (see settingsJSONData) — cosmetic.
    private static let observedEvents: [(name: String, hasMatcher: Bool)] = [
        ("UserPromptSubmit", false),
        ("PreToolUse", true),
        ("PostToolUse", true),
        ("Notification", false),
        ("Stop", false),
        ("SessionStart", false)
    ]

    /// Hook timeout in seconds. Generous enough that a briefly slow Opus
    /// (app launching, disk contention) never trips it under normal use,
    /// short enough that a genuinely hung/absent Opus can't stall claude —
    /// opus-attach itself is expected to return in well under a second
    /// regardless (connect-or-fail, no retries, no blocking waits).
    static let timeoutSeconds = 3

    /// Resolved path to the opus-attach binary the generated hooks invoke:
    /// prefer the binary bundled alongside Opus.app itself (the production
    /// install), falling back to ~/.local/bin/opus-attach — the same
    /// location SpawnEnvironment's PATH additions expect — when there's no
    /// real bundle to resolve (e.g. `swift build`/`swift test` from
    /// .build, where Bundle.main isn't a real .app).
    static var bundledBinaryPath: String {
        let bundled = Bundle.main.bundlePath + "/Contents/MacOS/opus-attach"
        if FileManager.default.fileExists(atPath: bundled) {
            return bundled
        }
        return NSHomeDirectory() + "/.local/bin/opus-attach"
    }

    /// ~/Library/Application Support/Opus — created on demand by
    /// ensureSettingsFile(). Note the literal space in "Application
    /// Support": both this directory and any dev checkout path can contain
    /// spaces, which is exactly why every consumer of this path (the
    /// generated hook `command` strings, and composeSpawnCommand's
    /// `--settings` flag) goes through shellQuote.
    static var settingsDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Opus", isDirectory: true)
    }

    static var settingsFileURL: URL {
        settingsDirectory.appendingPathComponent("opus-hooks.json")
    }

    /// Single-quoted absolute settings path, ready to append after
    /// `--settings ` in composeSpawnCommand. Static so SpawnCommandTests can
    /// build its expected strings against the SAME computed value instead of
    /// hardcoding a machine-dependent path.
    static var escapedSettingsPathForShell: String {
        shellQuote(settingsFileURL.path)
    }

    /// Single-quote a POSIX path so it survives the shell verbatim (spaces,
    /// parentheses, etc.) — same idiom as TerminalContainerView.shellQuote,
    /// duplicated here rather than shared (private, tiny, one call site
    /// each, not worth a cross-file dependency for).
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Pure JSON builder — no disk access, fully unit-testable.
    /// `binaryPath` is single-quoted into each hook's shell-form command.
    static func settingsJSONData(binaryPath: String) -> Data {
        var hooksObject: [String: Any] = [:]
        for event in observedEvents {
            let command = "\(shellQuote(binaryPath)) event \(event.name)"
            var entry: [String: Any] = [
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                        "timeout": timeoutSeconds
                    ]
                ]
            ]
            if event.hasMatcher { entry["matcher"] = "*" }
            hooksObject[event.name] = [entry]
        }
        let root: [String: Any] = ["hooks": hooksObject]
        // .sortedKeys makes the output byte-for-byte deterministic — both so
        // ensureSettingsFile's identical-content check is meaningful (a
        // Dictionary's natural iteration order is NOT guaranteed stable
        // across two calls) and so the written file is easy to diff by hand.
        // .withoutEscapingSlashes keeps paths readable (JSONSerialization
        // otherwise escapes every "/" as "\/" — valid JSON either way, but
        // needlessly noisy for a file whose entire content is filesystem
        // paths).
        return (try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
    }

    /// Writes the hooks file, but only when its content actually differs
    /// from what's already on disk — an unchanged rewrite would needlessly
    /// bump mtime (HookSettingsWriterTests asserts this). Returns the
    /// absolute path either way. `directory`/`binaryPath` are injectable so
    /// tests can exercise this against an isolated temp directory instead of
    /// the real ~/Library/Application Support.
    @discardableResult
    static func ensureSettingsFile(
        directory: URL = HookSettingsWriter.settingsDirectory,
        binaryPath: String = HookSettingsWriter.bundledBinaryPath
    ) -> String {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("opus-hooks.json")
        let newData = settingsJSONData(binaryPath: binaryPath)
        if let existing = try? Data(contentsOf: url), existing == newData {
            return url.path
        }
        // settingsJSONData only returns empty Data on a JSONSerialization
        // failure (its `?? Data()` fallback) — never write that out: a
        // zero-byte --settings file makes claude hard-fail on every
        // subsequent spawn (see the doc comment above), so a bad build is
        // strictly better than a bricked one.
        guard !newData.isEmpty else { return url.path }
        try? newData.write(to: url, options: .atomic)
        return url.path
    }
}
