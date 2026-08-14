// SecretRedactor — two independent passes, used by two different callers.
//
//   redactKnownValues  exact-matches values pulled from the store. Used by
//                      hook-post, where the set is small (only the secrets
//                      actually substituted this session) and precise.
//
//   redactCredentialPatterns  shape-matches well-known credential formats.
//                      Used by the prompt palette, where the leak predates
//                      the store and there is no value to match against.
//
// Both search ANYWHERE in the text, never anchored to the start of a line:
// a pasted "RESEND_API_KEY=re_live_..." is far more common than a bare
// token, so an anchored match would catch nothing real.

import Foundation

public struct SecretRedactor {
    /// Below this length a value is too generic to replace: redacting a
    /// three-character string would shred unrelated output.
    public static let minimumRedactableLength = 8

    private let entries: [(value: String, name: String)]

    public init(secrets: [(name: String, value: String)]) {
        // Longest first. If one stored value is a prefix of another,
        // replacing the shorter one first would leave the remainder of the
        // longer one exposed.
        entries = secrets
            .filter { $0.value.count >= Self.minimumRedactableLength }
            .map { (value: $0.value, name: $0.name) }
            .sorted { $0.value.count > $1.value.count }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// Replacement text can never contain a stored value, so a single pass
    /// per entry is a fixed point already. No loop needed here.
    public func redactKnownValues(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        var out = text
        for entry in entries {
            out = out.replacingOccurrences(of: entry.value, with: "[secret:\(entry.name)]")
        }
        return out
    }

    public func redact(_ text: String) -> String {
        Self.redactCredentialPatterns(redactKnownValues(text))
    }

    public static let credentialPatterns: [String] = [
        "sk-[A-Za-z0-9_-]{16,}",
        "sk_live_[A-Za-z0-9]{16,}",
        "pk_live_[A-Za-z0-9]{16,}",
        "re_[A-Za-z0-9_]{16,}",
        "ghp_[A-Za-z0-9]{30,}",
        "gho_[A-Za-z0-9]{30,}",
        "github_pat_[A-Za-z0-9_]{20,}",
        "AKIA[0-9A-Z]{16}",
        "ASIA[0-9A-Z]{16}",
        "appl_[A-Za-z0-9]{16,}",
        "xoxb-[A-Za-z0-9-]{10,}",
        "xoxp-[A-Za-z0-9-]{10,}",
        "hooks\\.slack\\.com/services/[A-Za-z0-9/]+",
        // Three segments, and the third may be empty (an unsigned alg=none
        // token ends in a bare dot). The previous pattern stopped at the
        // second dot and left the signature in the clear. The third segment
        // is optional so a two-segment token is still consumed whole rather
        // than not at all.
        "eyJ[A-Za-z0-9_-]{10,}\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]*)?",
        // The whole block, not the banner. The previous pattern matched only
        // -----BEGIN ...----- and left the key body and footer in the clear
        // while the output still showed [redacted], which is worse than no
        // redaction at all because nothing signals a problem. The trailing
        // `|$` is a deliberate fail-safe: a PEM whose END marker was cut off
        // by a truncated buffer is consumed to the end of the text rather
        // than escaping entirely.
        "-----BEGIN [A-Z ]*PRIVATE KEY-----[\\s\\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"
    ]

    // map + try!, never compactMap + try?. A compactMap would silently DROP
    // any pattern that failed to compile, and the redactor would keep
    // reporting success while that entire class of credential quietly
    // stopped being redacted. These patterns are compile-time constants, so
    // a failure is a programmer error that must surface in CI.
    private static let compiled: [NSRegularExpression] = credentialPatterns.map {
        try! NSRegularExpression(pattern: $0)
    }

    public static func redactCredentialPatterns(_ text: String) -> String {
        var out = text
        for regex in compiled {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: "[redacted]")
        }
        return out
    }

    /// Rebuild a decoded JSON value with every string transformed — leaf
    /// VALUES and dictionary KEYS alike — and every non-string leaf (Bool,
    /// Int, NSNull, ...) untouched. A tool's own stdout/stderr never puts a
    /// secret in a KEY, but a generic MCP tool returning an object keyed by
    /// a caller-supplied token is exactly a shape where it could — "every
    /// string in the response" has to mean every string, not every string
    /// found in the values.
    ///
    /// Preserving the exact shape (transform in place, rebuild the same
    /// container types, never drop or reorder a leaf) is not a style choice
    /// — it is what makes the result pass Claude Code's `updatedToolOutput`
    /// schema check, which validates against the ORIGINAL tool's output
    /// shape. A response that fails that check is not rejected outright:
    /// Claude Code silently falls back to the RAW, unredacted tool output
    /// plus an error attachment describing the schema mismatch — the exact
    /// "secret reaches the model" outcome this whole hook exists to
    /// prevent, and one no unit test here can catch, because a unit test
    /// only ever inspects this function's return value, never what the
    /// host does with it afterward (the same blind spot recorded on
    /// `HookRunner.encode`'s `suppressOutput` comment). A future rewrite
    /// that reconstructs the response by hand instead of walking the
    /// original structure would fail OPEN silently the moment it produces
    /// a shape Claude Code's validator rejects.
    public static func redactStrings(in object: Any, using transform: (String) -> String) -> Any {
        if let s = object as? String { return transform(s) }
        if let array = object as? [Any] { return array.map { redactStrings(in: $0, using: transform) } }
        if let dict = object as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, value) in dict { out[transform(key)] = redactStrings(in: value, using: transform) }
            return out
        }
        return object
    }
}
