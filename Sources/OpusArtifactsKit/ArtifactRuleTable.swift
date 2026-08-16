// ArtifactRuleTable — which input keys carry an artifact, and which tools
// are excluded outright.
//
// Verified empirically across 12 real transcripts under ~/.claude/projects
// on 15 August 2026. The key name is NOT uniform across tools: Write and
// Edit use file_path, screenshot tools use filename, browser tools use
// url, Bash hides paths inside a shell command.
//
// What this type is NOT is a per-tool mapping, whatever an earlier version
// of this comment promised. It is one set of key names per family, applied
// uniformly to every tool that is not denied — which is exactly what the
// spec asks for, because a new MCP tool that follows the convention is
// then covered with no code change at all. The per-tool knowledge that
// mattered went into `deniedTools`, since a `file_path` on `Read` is a
// read, not a product, and no shape of the key can tell you that.

import Foundation

public enum ArtifactRuleTable {
    /// Tools whose file arguments are reads, not products. The owner's
    /// explicit call: a session that reads forty files would bury the one
    /// image the drawer was opened to find.
    ///
    /// `WebFetch` and `WebSearch` join them for the URL half of the same
    /// argument: the chosen category was "web URLs I tell him about", not
    /// "URLs I consumed", and unlike paths, URLs have no downstream
    /// existence filter to thin them out. Any fetched page that actually
    /// matters gets named in the reply text, where the text scanner already
    /// catches it. `mcp__claude-in-chrome__navigate` is deliberately NOT
    /// denied: a page opened in the owner's own browser is closer to a
    /// product than to a read, and the final review measured it as the real
    /// URL traffic (55 occurrences against WebFetch's 8, while WebSearch
    /// carries no `url` key at all) — so these two strings match the stated
    /// intent rather than fixing any measured burial.
    public static let deniedTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "NotebookRead", "ToolSearch", "TaskOutput",
        "WebFetch", "WebSearch"
    ]

    /// Keys whose value is a path, or an array of paths. Applied to every
    /// tool that is not denied, which is what lets a new MCP tool following
    /// the convention work with no code change.
    public static let pathKeys: Set<String> = [
        "file_path", "path", "filename", "output_path", "notebook_path", "paths"
    ]

    /// Keys whose value is a URL.
    public static let urlKeys: Set<String> = ["url"]

    /// Keys whose value is prose or shell that must be scanned rather than
    /// taken whole.
    public static let textScanKeys: Set<String> = ["command"]
}
