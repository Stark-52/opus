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
}

public enum ClaudeSettingsMerger {
    /// Any hook command containing this substring is considered ours and is
    /// replaced rather than appended to, which is what makes a rerun
    /// idempotent and a moved binary self-healing.
    public static let commandMarker = "opus-secrets hook-"

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

            // Drop any previous registration of ours, at any binary path.
            entries.removeAll { entry in
                let commands = (entry["hooks"] as? [[String: Any]] ?? [])
                    .compactMap { $0["command"] as? String }
                return commands.contains { $0.contains(commandMarker) }
            }

            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": "\(binaryPath) \(registration.subcommand)",
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
    /// writes nothing at all, when the existing file is not valid JSON.
    @discardableResult
    public static func apply(
        settingsURL: URL,
        backupURL: URL,
        binaryPath: String,
        timeoutSeconds: Int
    ) throws -> Bool {
        let existingData = try? Data(contentsOf: settingsURL)

        var existing: [String: Any] = [:]
        if let existingData, !existingData.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                throw ClaudeSettingsMergeError.malformedExistingFile
            }
            existing = parsed
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

        if let existingData, !FileManager.default.fileExists(atPath: backupURL.path) {
            try? existingData.write(to: backupURL, options: .atomic)
        }

        try newData.write(to: settingsURL, options: .atomic)
        return true
    }
}
