// TaskListReader — pure parse + load for a Claude Code session's on-disk
// task list (v1.6 backlog Task 3, the Cmd+Shift+T "Tasks" drawer).
//
// On-disk shape, verified on this machine before writing this file (see
// task-3-brief.md's provenance note and ~/.claude/tasks/<session-id>/*.json
// for a real example):
//   ~/.claude/tasks/<session-id>/
//     1.json, 2.json, 3.json, …   — one JSON object per task, filename is
//                                    the task's own numeric id + ".json"
//     .lock                       — empty sentinel, NOT a task
//     .highwatermark              — small counter file, NOT a task
//
// A task JSON object looks like:
//   {"id":"1","subject":"Add the WebP encoder",
//    "description":"…","activeForm":"Adding the WebP encoder",
//    "status":"completed","blocks":[],"blockedBy":[]}
//
// This type only ever reads `id`/`subject`/`status` — `description`,
// `activeForm`, `blocks`, `blockedBy` are decoded by nobody here and simply
// ignored by JSONDecoder (extra keys in the JSON that aren't present on the
// Decodable struct are dropped, not an error).
//
// Threading: both `parse` and `load` are pure/synchronous disk-and-CPU work
// with no dependency on being called from any particular queue — the caller
// (TerminalContainerView's todo-drawer refresh) is the one responsible for
// hopping to a background queue before calling `load` and back to main
// before touching UI, same split as `readTranscriptTail`/`refreshContextMeter`.

import Foundation

/// A single Claude Code task, as far as the drawer needs to know.
struct ClaudeTask: Equatable {
    let id: String
    let subject: String
    let status: ClaudeTaskStatus
}

/// Mirrors the task-runner's own status vocabulary. `in_progress` is the
/// only field whose Swift case name doesn't match its raw JSON string
/// verbatim (`inProgress` vs. `"in_progress"`), spelled out via the
/// explicit rawValue below rather than relying on any automatic
/// snake_case-to-camelCase conversion.
enum ClaudeTaskStatus: String, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

enum TaskListReader {
    /// Only the fields this drawer displays. `status` is optional here (not
    /// on `ClaudeTask`) because a missing OR unrecognized status string both
    /// fall back to `.pending` — see `parse` below — rather than failing the
    /// whole record. `id`/`subject` stay non-optional: a task record without
    /// either of those is not a task this drawer can show at all, so the
    /// standard JSONDecoder "missing required key" failure is exactly the
    /// right behavior (parse returns nil for the whole record, same as
    /// genuinely malformed JSON).
    private struct RawTask: Decodable {
        let id: String
        let subject: String
        let status: String?
    }

    /// Parses one task JSON file's raw bytes. `nil` for anything that isn't
    /// a well-formed JSON object with at least `id` and `subject` — covers
    /// both truly malformed input (e.g. a non-JSON file that slipped past
    /// `load`'s filename filter) and a task file caught mid-write by a
    /// concurrent writer (a torn/partial JSON write reads back as invalid
    /// JSON, which JSONDecoder simply fails on — `load` below then just
    /// skips that one entry via `compactMap`, so a task mid-write is
    /// invisible for this refresh and reappears whole on the next poll,
    /// rather than crashing or showing a half task).
    static func parse(fileContents: Data) -> ClaudeTask? {
        guard let raw = try? JSONDecoder().decode(RawTask.self, from: fileContents) else { return nil }
        let status = raw.status.flatMap(ClaudeTaskStatus.init(rawValue:)) ?? .pending
        return ClaudeTask(id: raw.id, subject: raw.subject, status: status)
    }

    /// Loads every task under `tasksDir/<sessionId>/`, oldest-numbered
    /// first. Only filenames of the exact shape `<integer>.json` count as
    /// tasks — `.lock`, `.highwatermark`, and anything else (a stray
    /// `.DS_Store`, a future non-numeric sidecar file) are silently
    /// ignored, never handed to `parse`. Sorted by the INTEGER value of the
    /// filename's stem, not alphabetically — `10.json` must sort after
    /// `2.json`, which a plain string sort would get wrong.
    ///
    /// A missing directory (no tasks have ever been written for this
    /// session, or the session id doesn't exist on disk at all) returns an
    /// empty array rather than throwing — same "no data, not an error"
    /// shape as `ClaudeStateStore.state(forSessionId:)` defaulting to
    /// `.idle` for an unseen session.
    static func load(sessionId: String, tasksDir: URL, fileManager: FileManager = .default) -> [ClaudeTask] {
        let dir = tasksDir.appendingPathComponent(sessionId)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        let numbered: [(n: Int, url: URL)] = entries.compactMap { url in
            // `.lock`/`.highwatermark` are dotfiles with a leading dot and no
            // further dot in the name — Foundation's own pathExtension
            // parsing already reports an EMPTY extension for those (verified
            // on this machine: URL(fileURLWithPath: "/x/.lock").pathExtension
            // == ""), so the `== "json"` check alone excludes both without
            // needing an explicit name blocklist. `.skipsHiddenFiles` above
            // is belt-and-suspenders for the same two files (both are
            // dotfiles) — kept as an explicit second filter since "ignore
            // .lock/.highwatermark" is a named requirement, not just an
            // incidental side effect of the extension check.
            guard url.pathExtension == "json" else { return nil }
            guard let n = Int(url.deletingPathExtension().lastPathComponent) else { return nil }
            return (n, url)
        }

        return numbered
            .sorted { $0.n < $1.n }
            .compactMap { entry in
                guard let data = try? Data(contentsOf: entry.url) else { return nil }
                return parse(fileContents: data)
            }
    }
}
