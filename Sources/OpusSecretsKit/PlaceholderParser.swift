// PlaceholderParser — finds {{secret:<name>}} references in a command.
//
// The name inside the braces must satisfy SecretName.grammar, so a
// malformed placeholder is simply not a placeholder: it is left in the
// command untouched and will produce an ordinary failure downstream
// rather than being silently swallowed.
//
// This type deliberately does NOT resolve a placeholder into anything —
// see CommandSubstitutionRewriter for that job. It used to (a `substitute`
// method that replaced a placeholder with a resolved VALUE), back when
// hook-pre worked that way; it was removed once hook-pre stopped resolving
// values at all, because a tested-but-unused value-substitution function
// left sitting in a codebase whose whole point is "values are never
// substituted" is a trap for whoever reads it next.

import Foundation

public enum PlaceholderParser {
    public static let marker = "{{secret:"

    // try! deliberately. This pattern is a compile-time constant built from
    // SecretName.grammar, so it cannot fail on any input — a failure could
    // only mean a future edit to the grammar broke it. `try?` would return
    // nil and make names() report "no placeholders", which would let a
    // literal {{secret:x}} run as if it were the credential. Crashing in CI
    // beats silently disabling the control in production.
    private static let regex = try! NSRegularExpression(
        pattern: "\\{\\{secret:(\(SecretName.grammar))\\}\\}"
    )

    /// Cheap gate for the hook fast path: a plain substring search, no
    /// regex compile, no JSON parse.
    public static func containsMarker(_ text: String) -> Bool {
        text.contains(marker)
    }

    /// Every valid name referenced, in first-appearance order, deduplicated.
    public static func names(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var ordered: [String] = []
        var seen = Set<String>()
        for match in regex.matches(in: text, options: [], range: range) {
            guard let r = Range(match.range(at: 1), in: text) else { continue }
            let name = String(text[r])
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }
}
