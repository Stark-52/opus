// ArtifactRuleTable — which input keys of which tools carry an artifact.
//
// Verified empirically across 12 real transcripts under ~/.claude/projects
// on 15 August 2026. The key name is NOT uniform across tools: Write and
// Edit use file_path, screenshot tools use filename, browser tools use
// url, Bash hides paths inside a shell command. A table beats a heuristic
// because a typed key is an artifact by construction, with no false
// positives to filter out afterwards.

import Foundation

public enum ArtifactRuleTable {
    /// Tools whose file arguments are reads, not products. the owner's explicit
    /// call: a session that reads forty files would bury the one image he
    /// opened the drawer to find.
    public static let deniedTools: Set<String> = [
        "Read", "Grep", "Glob", "LS", "NotebookRead", "ToolSearch", "TaskOutput"
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
