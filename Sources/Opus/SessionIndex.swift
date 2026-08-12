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
//     record DOES exist and IS Claude's auto-generated conversation title,
//     regenerated (appended again, not rewritten in place) as the session
//     continues — but the FIRST one lands late: across 2,853 occurrences
//     sampled on this machine, the earliest byte offset was 82,817 — never
//     inside a 16KB head. A plain 16KB head-only read therefore surfaces an
//     ai-title for only ~43% of sessions (Fix round 1 measurement). What
//     DOES work at bounded cost: reading the file's TAIL too — across the
//     same sample, the distance from EOF back to the LAST ai-title record
//     ranged 321B..32,917B (median ~18.8KB), so a 40KB tail (see
//     `tailBudgetBytes`) catches 100% of them. `scan()` reads both ends;
//     `latestAiTitle` parses the tail with last-match-wins semantics (the
//     freshest regenerated title is the one worth showing).
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

    /// Bytes read from the END of a transcript (only when the file is bigger
    /// than `headBudgetBytes`) to catch a fresher ai-title record. Sized from
    /// a real measurement, not a guess: across 2,853 ai-title occurrences on
    /// this machine, the distance from EOF back to the LAST one per file
    /// ranged 321B..32,917B (median ~18.8KB) — 40KB comfortably covers 100%
    /// of the sample with headroom, at a bounded, cheap-per-file cost.
    static let tailBudgetBytes = 40 * 1024

    /// Compact, unsigned age for the palette's subtitle line. RelativeDateTimeFormatter
    /// emitted signed forms ("-27 s") in the abbreviated style, which read as broken.
    static func relativeAge(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "now" }

        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }

        let hours = seconds / 3600
        if hours < 24 { return "\(hours)h" }

        let days = seconds / 86400
        if days < 7 { return "\(days)d" }

        let weeks = seconds / (7 * 86400)
        if weeks < 5 { return "\(weeks)w" }

        let months = days / 30
        return "\(months)mo"
    }

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

    /// Scan a transcript's TAIL (see `tailBudgetBytes`) for `{"type":
    /// "ai-title","aiTitle":"..."}` records, keeping the LAST match — Claude
    /// appends a fresh one as the session continues, so the newest is the
    /// title worth showing. Pure — no filesystem access.
    ///
    /// The tail buffer starts at an arbitrary seek offset into the file, so
    /// its first "line" is almost always a partial record cut off mid-way
    /// through. That partial fragment is dropped unconditionally (bytes up
    /// to and including the first 0x0A) before line-splitting, rather than
    /// relying on it merely failing to parse as JSON — a truncated fragment
    /// that happens to look like valid-but-wrong JSON is a real (if remote)
    /// risk this guards against outright.
    static func latestAiTitle(jsonlTail: Data) -> String? {
        guard let firstNewline = jsonlTail.firstIndex(of: 0x0A) else { return nil }
        let body = jsonlTail[jsonlTail.index(after: firstNewline)...]

        var latest: String?
        for lineData in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  (obj["type"] as? String) == "ai-title",
                  let t = obj["aiTitle"] as? String, !t.isEmpty
            else { continue }
            latest = t
        }
        guard let latest else { return nil }
        return latest.count > 80 ? String(latest.prefix(80)) : latest
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

        struct Candidate { let url: URL; let sessionId: String; let mtime: Date; let size: UInt64 }
        var candidates: [Candidate] = []

        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue
            else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for f in files {
                guard f.pathExtension == "jsonl" else { continue }
                let sessionId = f.deletingPathExtension().lastPathComponent
                // UUID shape enforced here too — SessionSwitcherPanel feeds
                // this straight into ClaudeBackend.restart(mode: .resume(_)),
                // which lands in a shell command.
                guard UUID(uuidString: sessionId) != nil else { continue }
                let values = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = values?.contentModificationDate ?? .distantPast
                let size = UInt64(values?.fileSize ?? 0)
                candidates.append(Candidate(url: f, sessionId: sessionId, mtime: mtime, size: size))
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
            guard var summary = parseSummary(jsonlHead: head, sessionId: c.sessionId, mtime: c.mtime)
            else { continue }

            // Only worth the extra seek+read when the file didn't already
            // fit entirely inside the head we just read — otherwise
            // parseSummary already saw every byte the tail scan would see.
            if c.size > UInt64(headBudgetBytes) {
                let tailStart = c.size > UInt64(tailBudgetBytes) ? c.size - UInt64(tailBudgetBytes) : 0
                if (try? handle.seek(toOffset: tailStart)) != nil,
                   let tail = try? handle.readToEnd(),
                   let freshTitle = latestAiTitle(jsonlTail: tail) {
                    summary = SessionSummary(
                        sessionId: summary.sessionId,
                        cwd: summary.cwd,
                        title: freshTitle,
                        mtime: summary.mtime,
                        gitBranch: summary.gitBranch
                    )
                }
            }
            results.append(summary)
        }
        return results
    }
}
