// ContextMeter — parses a Claude Code transcript tail into a context-window
// usage fraction, for the thin burn-rate bar TerminalContainerView paints
// above its tab bar (Lot 3, Task 4).
//
// Real transcript shape (confirmed by inspecting this machine's OWN live
// session transcript while writing this file —
// ~/.claude/projects/-Users-dev-Documents-GitHub-Project/
// <session-id>.jsonl, the transcript this very task
// was worked from — 616 matching records found):
//   {"type":"assistant","message":{"model":"claude-fable-5", "usage": {
//       "input_tokens": 2,
//       "cache_creation_input_tokens": 2752,
//       "cache_read_input_tokens": 689241,
//       "output_tokens": 15,
//       "server_tool_use": {...}, "service_tier": "standard",
//       "cache_creation": {...}, "inference_geo": "not_available",
//       "iterations": [...], "speed": "standard"
//   }, ...}, ...}
// `message.usage` always carries (at least) `input_tokens`, `output_tokens`,
// `cache_creation_input_tokens`, `cache_read_input_tokens` as plain integers,
// plus several extra fields this parser ignores. `message.model` on the SAME
// record is a plain string ("claude-fable-5", "claude-opus-4-8", "claude-
// opus-5" all observed on this machine). No "[1m]" suffix was observed here,
// but that suffix is documented Anthropic API convention for the 1M-context
// beta (e.g. "claude-sonnet-4-20250514[1m]") — kept per the controller spec
// even though unconfirmed locally.
//
// Fix round 1 correction: every `type:"assistant"` record carries a `usage`
// key — my original claim that `<synthetic>`-model records omit it entirely
// was empirically wrong (reviewer re-verified across 12,076 real assistant
// records on this machine: 100% have a `usage` object; the 30 `<synthetic>`-
// model ones among them have `usage` present with every field zeroed —
// `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`,
// `output_tokens` all `0`). A zero-summed record is therefore a REAL,
// well-formed record that carries no information — treated as a non-match
// below (skip, keep the last real match) rather than as "the session's
// context is now empty," which is what naively accepting it as the newest
// match would have shown.
import AppKit
import Foundation

enum ContextMeter {
    /// Bytes read from the END of the active transcript by the caller
    /// (TerminalContainerView's 10s timer) before handing the buffer to
    /// `usage(fromTranscriptTail:)`. Sized generously above a single
    /// assistant record's typical serialized size (usually well under 2KB
    /// even with the `iterations`/`cache_creation` sub-objects) so the tail
    /// buffer reliably contains at least one, usually several, complete
    /// records to pick the true last one from.
    static let tailBudgetBytes = 32 * 1024

    /// Context-window ceiling for a model not matched by any more specific
    /// rule below.
    static let defaultLimit = 200_000

    /// The 1M-context beta's ceiling — see the file header re: "[1m]".
    static let oneMillionLimit = 1_000_000

    /// Static model-id → context-limit table. Substring match, not exact —
    /// real model ids carry dates/build suffixes ("claude-opus-4-8",
    /// "claude-sonnet-4-20250514[1m]") that a fixed lookup table would miss.
    private static func limit(forModel model: String?) -> Int {
        guard let model, model.contains("[1m]") else { return defaultLimit }
        return oneMillionLimit
    }

    /// Scans `data` (a transcript TAIL, not the whole file) for the LAST
    /// `{"type":"assistant", "message":{"model":..., "usage":{...}}}` record
    /// and returns the summed context tokens plus that record's resolved
    /// limit. `nil` when no such record is found anywhere in the buffer
    /// (empty transcript, tail landed entirely inside non-assistant records,
    /// or a session with no usage-bearing turns yet).
    ///
    /// Token sum is `input_tokens + cache_read_input_tokens +
    /// cache_creation_input_tokens` — deliberately EXCLUDES `output_tokens`.
    /// Those three fields are what Claude Code re-sends as input context on
    /// the NEXT turn (the previous turn's output becomes part of the next
    /// turn's input once it lands in the transcript); `output_tokens` is
    /// what was just generated and, on its own turn, was never part of the
    /// context window being measured.
    ///
    /// A record whose `message.usage` is missing (or isn't a JSON object)
    /// is skipped — the LAST-seen usage-bearing record still wins, same as
    /// a record that fails to parse as JSON at all. Last-match-wins reflects
    /// records being appended in transcript order: whichever came latest in
    /// the file is the freshest context snapshot.
    ///
    /// A record whose usage sums to exactly 0 is ALSO skipped (fold round 1
    /// fix) — see the file header's "Fix round 1 correction": real
    /// `<synthetic>`-model records carry a well-formed but all-zero `usage`
    /// object, and naively letting the LAST-in-file rule accept one would
    /// have the bar drop to a misleading "context window is empty" the
    /// moment one appears after a real turn, rather than keeping the prior
    /// real reading.
    ///
    /// Skips the tail buffer's first line unconditionally — same rule as
    /// `SessionIndex.latestAiTitle` (see that function's doc comment): a
    /// tail read starts at an arbitrary seek offset into the file, so its
    /// first "line" is virtually always a partial record cut off mid-way
    /// through. Dropping it outright (rather than relying on it merely
    /// failing to parse) also guards against a truncated fragment that
    /// happens to parse as valid-but-wrong JSON.
    static func usage(fromTranscriptTail data: Data) -> (tokens: Int, limit: Int)? {
        guard let firstNewline = data.firstIndex(of: 0x0A) else { return nil }
        let body = data[data.index(after: firstNewline)...]

        var result: (tokens: Int, limit: Int)?
        for lineData in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let input = usage["input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let tokens = input + cacheRead + cacheCreation
            // Zero-summed usage (real `<synthetic>`-model records — see file
            // header) carries no information; skip it so a real match
            // earlier in the tail keeps winning instead of being clobbered
            // by a misleading "empty" reading.
            guard tokens > 0 else { continue }
            result = (
                tokens: tokens,
                limit: limit(forModel: message["model"] as? String)
            )
        }
        return result
    }
}

/// 2pt-tall horizontal bar showing context-window burn: green up to 70% of
/// the limit, amber to 85%, red beyond. Track (the unfilled portion) draws
/// nothing — the bar reads as a floating sliver, not a visible rail, when
/// `fraction` is 0 or the container has hidden it via `alphaValue`.
final class ContextMeterBar: NSView {
    /// 0...1 — the caller (TerminalContainerView) is responsible for
    /// computing and clamping tokens/limit before assigning; clamped again
    /// here defensively so a stray out-of-range value never draws outside
    /// the view's own bounds.
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return }

        let fillColor: NSColor
        if clamped <= 0.70 {
            fillColor = .systemGreen
        } else if clamped <= 0.85 {
            fillColor = .systemOrange
        } else {
            fillColor = .systemRed
        }
        fillColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * clamped, height: bounds.height).fill()
    }
}
