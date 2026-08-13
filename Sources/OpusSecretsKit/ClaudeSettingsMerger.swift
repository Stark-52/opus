// ClaudeSettingsMerger — installs the three hooks into the user's OWN
// ~/.claude/settings.json, not into Opus's private --settings file.
//
// Why global: opus-hooks.json only reaches sessions Opus launches with the
// .claude preset. A session started from a plain terminal would see
// {{secret:x}} as literal text and send that literal string to a provider
// as if it were a credential. The enforcement has to be everywhere the
// placeholder can be written.
//
// The merge identifies its own entries by a marker inside the command
// string rather than by a sentinel key in the JSON. Claude Code validates
// settings.json, and an unknown top-level key would produce a warning on
// every start. The version lives in Opus's own preferences instead.

import Foundation

public enum ClaudeSettingsMergeError: Error {
    case malformedExistingFile
    case unreadableExistingFile(String)
    case backupFailed(String)
}

public enum ClaudeSettingsMerger {
    /// Any hook command matching one of these is considered ours and is
    /// replaced rather than appended to, which is what makes a rerun
    /// idempotent and a moved binary self-healing.
    ///
    /// Two forms, because the emitted command changed shape: the current one
    /// quotes the path, so the marker text is interrupted by the closing
    /// quote (`'…/opus-secrets' hook-pre`), while an entry written before
    /// quoting was added reads `…/opus-secrets hook-pre`. Matching both keeps
    /// a pre-existing installation migrating cleanly instead of duplicating.
    ///
    /// Matching the emitted forms rather than stripping quotes out of the
    /// input matters: a blanket strip also transforms the user's OWN hook
    /// commands, and an unrelated command carrying an apostrophe in the wrong
    /// place would be silently deleted as if it were ours.
    static let commandMarkers = ["opus-secrets' hook-", "opus-secrets hook-"]

    private static func isOurs(_ command: String) -> Bool {
        commandMarkers.contains { command.contains($0) }
    }

    /// Single-quote a POSIX path so it survives `sh -c` verbatim. A hook entry
    /// with no `args` key is SHELL form: Claude Code passes the command string
    /// to `sh -c`, so an unquoted path containing a space fails tokenisation
    /// and the binary is never invoked — PreToolUse and PostToolUse would
    /// silently stop firing, which for this feature means a secret silently
    /// not substituted and not redacted.
    ///
    /// Third copy of this idiom in the repo, deliberately: the one in
    /// HookSettingsWriter is private to the Opus app target and unreachable
    /// from this module, and TerminalContainerView's own copy records the same
    /// "tiny, one call site, not worth a cross-file dependency" reasoning.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let registrations: [(event: String, matcher: String?, subcommand: String)] = [
        ("PreToolUse", "Bash", "hook-pre"),
        ("PostToolUse", "*", "hook-post"),
        ("SessionStart", nil, "hook-session")
    ]

    public static func merged(
        into existing: [String: Any],
        binaryPath: String,
        timeoutSeconds: Int
    ) -> [String: Any] {
        var root = existing
        var hooks = (root["hooks"] as? [String: Any]) ?? [:]

        for registration in registrations {
            var entries = (hooks[registration.event] as? [[String: Any]]) ?? []

            // Remove only OUR commands from each entry's inner `hooks`
            // array, rather than dropping the whole entry the instant ANY
            // command in it matches: a user block bundling their own hook
            // next to a colliding one (same matcher group) would otherwise
            // lose both, not just the one being replaced. An entry left
            // with nothing of its own after filtering is dropped; one
            // where nothing changed is returned untouched.
            entries = entries.compactMap { entry -> [String: Any]? in
                guard let innerHooks = entry["hooks"] as? [[String: Any]] else { return entry }
                let kept = innerHooks.filter { !isOurs($0["command"] as? String ?? "") }
                if kept.count == innerHooks.count { return entry }
                guard !kept.isEmpty else { return nil }
                var updated = entry
                updated["hooks"] = kept
                return updated
            }

            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(shellQuote(binaryPath)) \(registration.subcommand)",
                    "timeout": timeoutSeconds
                ]]
            ]
            if let matcher = registration.matcher { entry["matcher"] = matcher }
            entries.append(entry)

            hooks[registration.event] = entries
        }

        root["hooks"] = hooks
        return root
    }

    /// Returns true when the file was actually rewritten. Throws, and
    /// writes nothing at all, when the existing file is not valid JSON, is
    /// present but unreadable, or when a backup could not be secured.
    @discardableResult
    public static func apply(
        settingsURL: URL,
        backupURL: URL,
        binaryPath: String,
        timeoutSeconds: Int
    ) throws -> Bool {
        // Existence and readability are different questions. Treating an
        // unreadable file as absent would merge into an empty base, skip the
        // backup because there is nothing to back up, and replace the user's
        // entire settings file with three hook entries.
        var existingData: Data?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                existingData = try Data(contentsOf: settingsURL)
            } catch {
                throw ClaudeSettingsMergeError.unreadableExistingFile(String(describing: error))
            }
        }

        var existing: [String: Any] = [:]
        if let existingData, !existingData.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                throw ClaudeSettingsMergeError.malformedExistingFile
            }
            existing = parsed
        }

        // A valid JSON object whose "hooks" key is the wrong shape (e.g.
        // `{"hooks": "oops"}`, a string where an object belongs) used to be
        // silently accepted here: `merged(into:)` casts with `as?` and
        // falls back to an empty dictionary on a mismatch, discarding
        // whatever the user actually typed with no error at all. Treated as
        // malformed, same as top-level invalid JSON, so the file is refused
        // rather than half-understood.
        if let hooksValue = existing["hooks"], !(hooksValue is [String: Any]) {
            throw ClaudeSettingsMergeError.malformedExistingFile
        }

        let merged = merged(into: existing, binaryPath: binaryPath, timeoutSeconds: timeoutSeconds)
        guard let newData = try? JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return false }

        // Compare semantically, not byte-wise: the file on disk was almost
        // certainly not written with our formatting options, so a byte
        // comparison would rewrite it on every launch.
        if let onDisk = try? JSONSerialization.data(
            withJSONObject: existing, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), onDisk == newData {
            return false
        }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A regular file already at backupURL means an earlier run already
        // secured the backup — skip it. Anything else there (nothing, or a
        // directory occupying the path) is NOT a valid backup, so the write
        // must still be attempted so a real obstruction surfaces as a thrown
        // error instead of being mistaken for "already backed up".
        var backupIsDirectory: ObjCBool = false
        let backupFileAlreadyExists = FileManager.default.fileExists(
            atPath: backupURL.path, isDirectory: &backupIsDirectory
        ) && !backupIsDirectory.boolValue

        if let existingData, !backupFileAlreadyExists {
            do {
                try existingData.write(to: backupURL, options: .atomic)
            } catch {
                // Refuse to touch the user's settings when we cannot first
                // secure a copy of what was there. This is the run that
                // matters: the first real change to a pristine file. Writing
                // anyway and returning true would leave them with no way back
                // and no signal that anything went wrong.
                throw ClaudeSettingsMergeError.backupFailed(String(describing: error))
            }
        }

        try newData.write(to: settingsURL, options: .atomic)
        return true
    }
}
