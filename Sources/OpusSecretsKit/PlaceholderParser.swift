// PlaceholderParser — finds and expands {{secret:<name>}} in a command.
//
// The name inside the braces must satisfy SecretName.grammar, so a
// malformed placeholder is simply not a placeholder: it is left in the
// command untouched and will produce an ordinary failure downstream
// rather than being silently swallowed.
//
// Substitution is a SINGLE left-to-right pass over the matches found in
// the ORIGINAL string. It deliberately does not rescan what it inserted:
// a stored value that happens to contain "{{secret:other}}" must not be
// able to reach a second secret.

import Foundation

public enum PlaceholderParser {
    public static let marker = "{{secret:"

    // try! deliberately. This pattern is a compile-time constant built from
    // SecretName.grammar, so it cannot fail on any input — a failure could
    // only mean a future edit to the grammar broke it. `try?` would return
    // nil and make names()/substitute() report "no placeholders", which
    // would let a literal {{secret:x}} run as if it were the credential.
    // Crashing in CI beats silently disabling the control in production.
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

    /// Replace each placeholder whose name is present in `values`. A
    /// placeholder with no entry is left exactly as written.
    public static func substitute(_ text: String, values: [String: String]) -> String {
        guard containsMarker(text) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text),
                  let nameRange = Range(match.range(at: 1), in: text)
            else { continue }
            out += text[cursor..<whole.lowerBound]
            let name = String(text[nameRange])
            out += values[name] ?? String(text[whole])
            cursor = whole.upperBound
        }
        out += text[cursor...]
        return out
    }
}
