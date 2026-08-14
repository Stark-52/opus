// SecretExtractor — turns whatever the owner actually copied into candidates.
//
// The premise, from the spec: he rarely copies a bare token. He copies a
// .env line, an Authorization header, a chunk of JSON. Asking him to
// hand-strip the value defeats the point of the panel, so the panel
// strips it and SHOWS him what it extracted (maskedPreview) rather than
// storing something silently wrong.

import Foundation

public struct SecretCandidate: Equatable {
    public let suggestedName: String
    public let value: String

    public init(suggestedName: String, value: String) {
        self.suggestedName = suggestedName
        self.value = value
    }
}

public enum SecretExtractor {
    /// Clipboard contents larger than this are not offered at all: a blob
    /// that big is a document, not a credential.
    public static let maximumBlobBytes = 8 * 1024

    // try!, same reasoning as SecretName and PlaceholderParser: a
    // compile-time constant cannot fail on input, so a failure is a
    // programmer error that belongs in CI. `try?` here would silently
    // degrade every line to the bare-token path, turning `KEY=value` into a
    // candidate whose value is the whole line.
    // The value group is `(.*?)`, not `(.+?)`: it must also match an EMPTY
    // value (`FOO=` with nothing after the `=`) so that case reaches the
    // `guard !value.isEmpty else { return nil }` below and is skipped
    // outright, rather than falling through to the bare-token path below
    // and being filed as a nameless candidate whose value is the literal
    // text "FOO=". Behaviourally identical to `(.+?)` for every non-empty
    // value — the non-greedy quantifier already expands to the minimum
    // needed to satisfy the trailing anchor either way.
    private static let assignment = try! NSRegularExpression(
        pattern: "^\\s*(?:export\\s+)?[\"']?([A-Za-z0-9_.-]+)[\"']?\\s*([=:])\\s*(.*?)\\s*,?\\s*$"
    )

    public static func candidates(from blob: String) -> [SecretCandidate] {
        var out: [SecretCandidate] = []
        // Split on Character.isNewline, NOT on split(separator: "\n"). Swift
        // groups CR+LF into ONE extended grapheme cluster, so the "\n"
        // Character matches nothing in a CRLF blob and the whole paste comes
        // back as a single line. A .env copied out of a Windows-origin file
        // is exactly that case. isNewline is true for the "\r\n" cluster, a
        // lone \r, and U+2028/U+2029.
        for rawLine in blob.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") { continue }
            if let candidate = candidate(fromLine: line) { out.append(candidate) }
        }
        return out
    }

    private static func candidate(fromLine line: String) -> SecretCandidate? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        if let m = assignment.firstMatch(in: line, options: [], range: range),
           let keyRange = Range(m.range(at: 1), in: line),
           let sepRange = Range(m.range(at: 2), in: line),
           let valRange = Range(m.range(at: 3), in: line) {
            let key = String(line[keyRange])
            let separator = String(line[sepRange])
            var value = unquote(String(line[valRange]))

            // A colon does not always mean an assignment. `https://host/path`
            // would otherwise be filed as the name "https" with its scheme
            // stripped off the value, and `C:\Users\...` as the name "c".
            // Both are realistic pastes. Gate on the separator that actually
            // matched, so `PATH_PREFIX=//shared` stays a genuine assignment.
            let isURI = separator == ":" && value.hasPrefix("//")
            let isWindowsPath = separator == ":" && key.count == 1 && value.hasPrefix("\\")
            if !isURI && !isWindowsPath {
                // "Authorization: Bearer <token>" — the scheme word is not
                // part of the credential. Strip at most one.
                for scheme in ["Bearer ", "Token ", "Basic "] where value.hasPrefix(scheme) {
                    value = String(value.dropFirst(scheme.count))
                    break
                }
                value = value.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { return nil }
                return SecretCandidate(suggestedName: SecretName.slug(key), value: value)
            }
        }
        // Bare token: one whitespace-free run on its own line. Prose has
        // spaces, so requiring none is what keeps a sentence from becoming
        // a candidate.
        guard !line.contains(" "), !line.contains("\t") else { return nil }
        return SecretCandidate(suggestedName: "", value: line)
    }

    private static func unquote(_ s: String) -> String {
        for quote in ["\"", "'"] where s.hasPrefix(quote) && s.hasSuffix(quote) && s.count >= 2 {
            return String(s.dropFirst().dropLast())
        }
        return s
    }

    /// Just the masked characters, no length suffix — used wherever the
    /// length is shown separately, such as its own table column. Values too
    /// short to give away four characters show none.
    public static func maskedValue(_ value: String) -> String {
        guard value.count >= 8 else { return "……" }
        return "\(value.prefix(2))…\(value.suffix(2))"
    }

    /// Shows enough for the owner to recognise the value and confirm the
    /// extraction was right, without printing it. Built from maskedValue
    /// plus the length, so there is exactly one masking rule regardless of
    /// how many places end up displaying it.
    public static func maskedPreview(_ value: String) -> String {
        "\(maskedValue(value)) (\(value.count) car.)"
    }

    /// Characters the shell interprets. A value containing any of these
    /// can break the quoting of the command it is substituted into (see
    /// spec section 11, risk 2), so the panel warns and points at
    /// `opus-secrets run`.
    public static func isShellHostile(_ value: String) -> Bool {
        // Newlines go through isNewline rather than set membership: the same
        // CRLF trap as above, a "\r\n" Character is not a member of a set
        // holding "\n" and "\r" separately.
        value.contains { $0.isNewline || "'\"`\\$".contains($0) }
    }
}
