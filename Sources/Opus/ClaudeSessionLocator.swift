// ClaudeSessionLocator — finds the Claude Code session ID for a working
// directory so a restarted backend can `claude --resume <id>` into the exact
// same conversation. Claude Code stores transcripts under
// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl ; the most recently
// modified .jsonl in that dir is the session that was live last.

import Foundation

enum ClaudeSessionLocator {
    /// Encodings of a cwd into Claude Code's project dir name, most likely
    /// first. Current versions map "/" → "-" and keep dots; older versions
    /// replaced every non-alphanumeric character with "-".
    static func projectDirNameCandidates(for cwd: String) -> [String] {
        let current = cwd.replacingOccurrences(of: "/", with: "-")
        let legacy = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        return current == legacy ? [current] : [current, legacy]
    }

    /// UUID (filename sans .jsonl) of the most recently modified session in
    /// the project dir for `cwd`, or nil when no dir/sessions exist.
    static func mostRecentSessionId(
        for cwd: String,
        projectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects")
    ) -> String? {
        let fm = FileManager.default
        for name in projectDirNameCandidates(for: cwd) {
            let dir = projectsRoot.appendingPathComponent(name)
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            // Enforce UUID shape — the ID is interpolated unquoted into a
            // zsh command (`--resume <id>`), so never trust raw filenames.
            let newest = files
                .filter { $0.pathExtension == "jsonl" }
                .filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
                .max { a, b in
                    let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate) ?? .distantPast
                    return da < db
                }
            if let newest {
                return newest.deletingPathExtension().lastPathComponent
            }
        }
        return nil
    }
}
