import Foundation

/// One runnable script, as the panel sees it.
///
/// A script is just an executable file in the scripts folder. Everything the
/// panel displays beyond the filename is optional metadata the file declares
/// about itself, so a script dropped in with no ceremony still shows up and
/// still runs.
public struct ScriptDefinition: Equatable, Identifiable, Sendable {
    /// The file's path. Identity is the PATH, never the display name: two
    /// scripts are allowed to present the same name, and run state is tracked
    /// per file.
    public let id: String
    public let url: URL
    public let displayName: String
    public let summary: String

    public init(url: URL, displayName: String, summary: String) {
        self.id = url.path
        self.url = url
        self.displayName = displayName
        self.summary = summary
    }
}

/// Reads the `# opus:` / `# opus-desc:` lines a script may declare about
/// itself.
///
/// The syntax is a comment in every shell this will ever run, so the header
/// costs the script nothing and breaks nothing if the panel never reads it.
public enum ScriptHeader {
    static let namePrefix = "# opus:"
    static let summaryPrefix = "# opus-desc:"

    /// How far into the file a header may appear. Bounded on purpose: a line
    /// matching the syntax three hundred lines down is a coincidence inside
    /// the body, not a declaration, and reading the whole file to find out
    /// would mean reading every script in the folder in full on every scan.
    static let maximumHeaderLines = 20

    /// Returns (displayName, summary). Either may be empty, which the caller
    /// resolves — the parser does not invent a fallback, so the fallback rule
    /// lives in exactly one place.
    public static func parse(_ contents: String) -> (name: String, summary: String) {
        var name = ""
        var summary = ""
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false)
                            .prefix(maximumHeaderLines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Longest prefix first: "# opus-desc:" also starts with "# opus:"
            // minus the colon, and testing the short one first would file
            // every description under the name.
            if trimmed.hasPrefix(summaryPrefix) {
                let value = trimmed.dropFirst(summaryPrefix.count).trimmingCharacters(in: .whitespaces)
                if summary.isEmpty { summary = value }
            } else if trimmed.hasPrefix(namePrefix) {
                let value = trimmed.dropFirst(namePrefix.count).trimmingCharacters(in: .whitespaces)
                if name.isEmpty { name = value }
            }
        }
        return (name, summary)
    }
}
