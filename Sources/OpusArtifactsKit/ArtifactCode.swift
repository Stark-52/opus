// ArtifactCode: the source and configuration files a session touches by the
// dozen and nobody opens from the drawer. They get their own chip, and "All"
// leaves them out.

import Foundation

public enum ArtifactCode {
    /// Compared lowercased against the path extension. Documents a person
    /// reads (`md`, `pdf`, `html`, `txt`, `csv`) are deliberately absent.
    public static let extensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs",
        "java", "kt", "c", "h", "cpp", "m", "mm", "sh", "zsh", "json", "yml",
        "yaml", "toml", "lock", "xml", "plist", "css", "scss",
    ]

    /// Files only: a folder named like a source file is still a folder.
    public static func isCode(_ artifact: Artifact) -> Bool {
        guard artifact.kind == .file, let path = artifact.resolvedPath else { return false }
        return extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
