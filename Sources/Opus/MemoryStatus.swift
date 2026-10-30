// MemoryStatus — the memory domains the memory-router mod has loaded in a
// session, for the rail.
//
// Inside Opus the mod draws no band above Claude Code's prompt. It writes
// Application Support/Opus/memory/<session id>.json, `{"domains": [...]}`,
// each time the list changes, and Opus reads that file and nothing else,
// the way it reads usage.json from the status line command.

import Foundation

enum MemoryStatus {
    static func fileURL(sessionId: String) -> URL {
        HookSettingsWriter.settingsDirectory
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("\(sessionId).json")
    }

    /// "mémoire : Atelier · Jeu", or "mémoire : socle" when no
    /// domain is loaded; nil for a malformed file.
    static func label(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let domains = root["domains"] as? [String]
        else { return nil }

        return "mémoire : " + (domains.isEmpty ? "socle" : domains.joined(separator: " · "))
    }

    /// Nil when the session has no file: the mod is not loaded, or the
    /// project has no domain files.
    static func read(sessionId: String) -> String? {
        (try? Data(contentsOf: fileURL(sessionId: sessionId))).flatMap(label)
    }
}
