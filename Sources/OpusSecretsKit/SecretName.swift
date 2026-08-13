// SecretName — the one place the secret-name grammar lives.
//
// The grammar is deliberately narrow: lowercase alphanumerics plus dot,
// dash and underscore, first character alphanumeric, 64 max. That keeps
// PlaceholderParser's regex tight enough that a name can never contain a
// brace, a quote, or anything else that would let a crafted name change
// the shape of the command it is substituted into.
//
// Validation is deliberately MORE permissive than `slug`. They are
// different jobs: slug picks one canonical form when deriving a name from
// an env var (RESEND_API_KEY becomes resend-api-key), while a name typed
// by hand may keep the underscore the typist is used to. Normalizing and
// accepting are not the same question.

import Foundation

public enum SecretName {
    /// Regex body without anchors, so PlaceholderParser can embed it.
    public static let grammar = "[a-z0-9][a-z0-9._-]{0,63}"

    // try! deliberately, and hoisted to a stored property so it compiles
    // once instead of on every call (isValid runs once per line on the
    // hook-post path via SessionUsage.names). This pattern is a
    // compile-time constant built from `grammar`, so it cannot fail on any
    // input — a failure could only mean a future edit to the grammar broke
    // it. `try?` would return nil and make isValid reject every name,
    // meaning nothing could ever be stored. Crashing in CI beats that.
    private static let validator = try! NSRegularExpression(pattern: "^\(grammar)$")

    public static func isValid(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return Self.validator.firstMatch(in: name, options: [], range: range) != nil
    }

    /// Best-effort conversion of arbitrary text (an env var name, a JSON
    /// key, an HTTP header) into a name that satisfies the grammar.
    /// Returns "" when nothing usable survives; callers treat that as
    /// "ask the user to type a name".
    public static func slug(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if ch == "." || ch == "-" {
                out.append(ch)
            } else if ch == "_" || ch == " " {
                out.append("-")
            }
            // Everything else is dropped.
        }

        // Fixed-point collapse. A single pass over "---" leaves "--", which
        // still contains the pattern being removed, so this loops until the
        // string stops changing rather than replacing once.
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }

        while let first = out.first, !(first.isASCII && (first.isLetter || first.isNumber)) {
            out.removeFirst()
        }
        while let last = out.last, last == "-" || last == "." {
            out.removeLast()
        }

        return String(out.prefix(64))
    }
}
