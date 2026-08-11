// SessionIndex — scans ~/.claude/projects/*/*.jsonl to build the Cmd+K
// conversation switcher's list. Every transcript on this machine (any
// project, any cwd) is a candidate, unlike ClaudeSessionLocator which only
// looks at the ONE project dir matching the current working directory.
//
// Parsing is pure and reads only a bounded head of each file (16KB) — a
// transcript can run to tens of megabytes and we may scan ~40 of them per
// keystroke-adjacent open, so reading whole files is not an option.
//
// Real-transcript shape (confirmed by inspecting this machine's
// ~/.claude/projects/ — see task-3-report.md for the full survey):
//   - Every record (system/attachment/user/assistant/...) that carries a
//     `cwd` field has it from the very first record onward — always well
//     within 16KB.
//   - `gitBranch` rides along on the same early records.
//   - A dedicated `{"type":"ai-title","aiTitle":"...","sessionId":"..."}`
//     record DOES exist and IS Claude's auto-generated conversation title —
//     but it lands late: across 2,853 occurrences sampled on this machine,
//     the EARLIEST byte offset was 82,817 — never inside a 16KB head. The
//     branch below is implemented and tested (a future larger budget or a
//     short transcript could reach it) but in practice today it will not
//     fire; the first-user-message / folder-name fallback carries the title.
import Foundation

struct SessionSummary: Equatable {
    let sessionId: String
    let cwd: String
    let title: String
    let mtime: Date
    let gitBranch: String?
}

enum SessionIndex {
    /// Bytes read per transcript — enough to reach the first several records
    /// (cwd/gitBranch/first user turn) without ever reading a whole file.
    static let headBudgetBytes = 16 * 1024

    /// Parse a session summary out of the first ~16KB of a transcript.
    /// Pure — no filesystem access. Safe on a head buffer whose last line is
    /// mid-record (truncated by the byte cutoff): line-splitting plus
    /// best-effort JSON parsing means a broken trailing line is just skipped.
    static func parseSummary(jsonlHead: Data, sessionId: String, mtime: Date) -> SessionSummary? {
        var cwd: String?
        var gitBranch: String?
        var firstUserTitle: String?
        var aiTitle: String?

        for lineData in jsonlHead.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }

            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty {
                gitBranch = b
            }
            // Claude's async title-generation record — see file header. Gated
            // on `type` so we don't false-positive on an unrelated field that
            // happens to be named "aiTitle" on some other record shape.
            if aiTitle == nil,
               (obj["type"] as? String) == "ai-title",
               let t = obj["aiTitle"] as? String, !t.isEmpty {
                aiTitle = t
            }
            if firstUserTitle == nil,
               (obj["type"] as? String) == "user",
               (obj["isMeta"] as? Bool) != true,
               let message = obj["message"] as? [String: Any] {
                if let s = message["content"] as? String, !s.isEmpty {
                    firstUserTitle = s
                } else if let blocks = message["content"] as? [[String: Any]] {
                    let text = blocks
                        .compactMap { $0["text"] as? String }
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { firstUserTitle = text }
                }
            }
        }

        guard let cwd else { return nil }

        let resolved = aiTitle
            ?? firstUserTitle
            ?? (cwd as NSString).lastPathComponent
        let truncated = resolved.count > 80 ? String(resolved.prefix(80)) : resolved

        return SessionSummary(
            sessionId: sessionId,
            cwd: cwd,
            title: truncated,
            mtime: mtime,
            gitBranch: gitBranch
        )
    }

    /// Enumerate every transcript under `projectsDir` (one level of project
    /// subdirectories, `.jsonl` files with UUID-shaped names — same shape
    /// check as ClaudeSessionLocator, since these IDs are interpolated
    /// unquoted into `claude --resume <id>`), newest-mtime first, and parse
    /// up to `limit` summaries. Reads at most `headBudgetBytes` per file.
    static func scan(
        projectsDir: URL,
        limit: Int = 40,
        fileManager: FileManager = .default
    ) -> [SessionSummary] {
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        struct Candidate { let url: URL; let sessionId: String; let mtime: Date }
        var candidates: [Candidate] = []

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files {
                guard f.pathExtension == "jsonl" else { continue }
                let sessionId = f.deletingPathExtension().lastPathComponent
                // UUID shape enforced here too — SessionSwitcherPanel feeds
                // this straight into ClaudeBackend.restart(mode: .resume(_)),
                // which lands in a shell command.
                guard UUID(uuidString: sessionId) != nil else { continue }
                let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                candidates.append(Candidate(url: f, sessionId: sessionId, mtime: mtime))
            }
        }

        candidates.sort { $0.mtime > $1.mtime }

        var results: [SessionSummary] = []
        results.reserveCapacity(min(limit, candidates.count))
        for c in candidates {
            if results.count >= limit { break }
            guard let handle = try? FileHandle(forReadingFrom: c.url) else { continue }
            defer { try? handle.close() }
            let head = handle.readData(ofLength: headBudgetBytes)
            if let summary = parseSummary(jsonlHead: head, sessionId: c.sessionId, mtime: c.mtime) {
                results.append(summary)
            }
        }
        return results
    }
}
