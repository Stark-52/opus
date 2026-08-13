// PromptHistory — parses ~/.claude/history.jsonl, the flat, append-only log
// of every prompt the user has typed into Claude Code (any project, any
// session) on this machine. Backs the Cmd+Shift+P prompt palette
// (PromptPalettePanel), which searches across ALL of it, not just the
// active scrollback.
//
// Real-file shape (confirmed against this machine's ~/.claude/history.jsonl,
// 2.8MB / ~7,500 lines, append-only, newest last): one JSON object per
// line —
//   {"display":"...","pastedContents":{...},"timestamp":<ms>,"project":"...","sessionId":"..."}
// `display` is the literal typed text UNLESS the user pasted something, in
// which case it's a placeholder like "[Pasted text #1 +19 lines]" and the
// real text lives in `pastedContents`, keyed by paste index ("1", "2"...).
//
// Parsing is pure (`parse(line:)`, no filesystem access) — same split as
// SessionIndex: a pure per-record parser plus a `load` that owns all the
// filesystem/dedup policy.
import Foundation
import OpusSecretsKit

struct PromptEntry: Equatable {
    let text: String
    let project: String
    let timestamp: Date
}

enum PromptHistory {
    /// Bytes read from the END of history.jsonl. The file is append-only
    /// and can grow to multiple megabytes over a machine's lifetime — a
    /// palette meant to surface RECENT prompts has no reason to read it
    /// whole. 512KB comfortably covers several hundred/thousand lines even
    /// with long pasted prompts mixed in.
    static let tailBudgetBytes = 512 * 1024

    /// Parse one line of history.jsonl. `nil` on malformed JSON or an empty
    /// (and nothing-pasted) `display`. `project` is optional in the wild —
    /// falls back to `""`.
    ///
    /// `redactor` defaults to a pattern-only redactor: history.jsonl keeps
    /// pasted content verbatim (see this file's header) and the palette
    /// re-inserts it, so a key pasted once was, until this change, a
    /// searchable and re-insertable row. The file is left alone, since it
    /// belongs to Claude Code; only what Opus SHOWS is filtered.
    static func parse(line: Data, redactor: SecretRedactor = SecretRedactor(secrets: [])) -> PromptEntry? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return nil
        }
        guard let display = obj["display"] as? String, !display.isEmpty else {
            return nil
        }
        guard let millis = obj["timestamp"] as? Double else { return nil }

        var text = display
        if let pasted = obj["pastedContents"] as? [String: Any], !pasted.isEmpty {
            // Keys are the paste index as a string ("1", "2"...) with no
            // ordering guarantee from JSONSerialization — sort numerically
            // so multiple pastes in one prompt concatenate in the order the
            // user actually pasted them, not dictionary order.
            let orderedKeys = pasted.keys.compactMap { Int($0) }.sorted()
            let contents = orderedKeys.compactMap { key -> String? in
                (pasted[String(key)] as? [String: Any])?["content"] as? String
            }
            if !contents.isEmpty {
                text = contents.joined(separator: "\n")
            }
        }

        text = redactor.redact(text)

        // A prompt that was nothing but a credential is now nothing but a
        // marker. Dropping it keeps the palette free of dead rows.
        let residue = text.replacingOccurrences(of: "[redacted]", with: "")
            .replacingOccurrences(of: "[secret:", with: "")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if residue.isEmpty { return nil }

        let project = obj["project"] as? String ?? ""
        return PromptEntry(text: text, project: project, timestamp: Date(timeIntervalSince1970: millis / 1000))
    }

    /// Read the LAST `tailBudgetBytes` of `url` (append-only, newest-last),
    /// drop a leading partial line ONLY when the seek actually landed mid-
    /// file (same rule/rationale as `SessionIndex.latestAiTitle` — the tail
    /// buffer starts at an arbitrary byte offset, so its first "line" is
    /// almost always a fragment; but when the whole file fits inside the
    /// window, byte 0 IS the start of a real line, and dropping it would
    /// silently lose the single oldest prompt for anyone with a short
    /// history). Parses each remaining line, reverses to newest-first,
    /// dedupes identical prompt TEXT keeping the most recent occurrence,
    /// then truncates to `limit`.
    ///
    /// A raw 0x0A byte only ever appears BETWEEN records here, never inside
    /// one: `display`/`pastedContents` are JSON string values, so any
    /// newline a user actually typed or pasted is escaped as the two
    /// characters `\n`, not a literal line-feed byte. So a 512KB cut always
    /// lands cleanly between two whole records, EXCEPT for whichever record
    /// straddles the cut itself — the "leading partial line" dropped above.
    ///
    /// That dropped record is NOT necessarily a small fragment: a single
    /// record LARGER than `tailBudgetBytes` (a prompt with enough pasted
    /// content) is real, and it is silently dropped in full, not "impossible"
    /// — the cut lands inside it, `firstIndex(of: 0x0A)` finds (at best) the
    /// newline that ends it, and everything up to and including that
    /// newline — i.e. the entire oversized record — is discarded as the
    /// "leading partial line," the same as a genuinely tiny fragment would
    /// be. If that oversized record is also the newest one in the file (no
    /// later newline exists in the tail at all), `body` falls through to the
    /// raw, still-truncated tail instead, which fails `parse(line:)` as
    /// malformed JSON and is dropped in the loop below instead — same net
    /// result, one prompt silently missing from the returned list.
    static func load(url: URL, limit: Int = 300, redactor: SecretRedactor = SecretRedactor(secrets: [])) -> [PromptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }

        let tailStart = size > UInt64(tailBudgetBytes) ? size - UInt64(tailBudgetBytes) : 0
        guard (try? handle.seek(toOffset: tailStart)) != nil,
              let tail = try? handle.readToEnd()
        else { return [] }

        let body: Data
        if tailStart > 0, let firstNewline = tail.firstIndex(of: 0x0A) {
            body = tail[tail.index(after: firstNewline)...]
        } else {
            body = tail
        }

        var entries: [PromptEntry] = []
        for lineData in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = parse(line: Data(lineData), redactor: redactor) {
                entries.append(entry)
            }
        }

        entries.reverse()   // newest-first

        // Dedupe by identical text, keeping the MOST RECENT occurrence.
        // `entries` is already newest-first at this point, so a plain
        // "first one wins" pass over a seen-set does exactly that — exact
        // (case-sensitive) string equality: two prompts differing only in
        // case are treated as distinct, deliberately, since a re-typed
        // prompt whose casing changed is arguably a different prompt, not
        // a re-use of the old one.
        var seen = Set<String>()
        var deduped: [PromptEntry] = []
        deduped.reserveCapacity(entries.count)
        for entry in entries where seen.insert(entry.text).inserted {
            deduped.append(entry)
        }

        return Array(deduped.prefix(limit))
    }
}
