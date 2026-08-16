// ArtifactClassifier — the only place the disk gets a vote.
//
// Text scanning is generous by design (see TextArtifactScanner). This is
// what makes that safe: a candidate that names nothing on disk is dropped,
// so `v1.2.3`, `0.85` and `node.js` never reach the drawer. No rule of
// form achieves that; only existence does.
//
// `isImage` is injected alongside `fileManager` so the Kit stays free of
// UniformTypeIdentifiers at the type level and the extension check can be
// exercised without creating real image files.

import Foundation
import UniformTypeIdentifiers

public enum ArtifactClassifier {

    public static func defaultIsImage(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    public static func classify(
        _ candidate: ArtifactCandidate,
        fileManager: FileManager = .default,
        isImage: (String) -> Bool = ArtifactClassifier.defaultIsImage
    ) -> Artifact? {
        switch candidate.payload {
        case .url(let raw):
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host
            else { return nil }
            var path = url.path
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            // Port is part of the dedup identity: two local servers on
            // different ports (localhost:3000 vs localhost:8080) are
            // different resources, and URL.host alone can't tell them
            // apart. url.port is nil unless the URL text carried an
            // explicit port, so a bare host and an explicit default port
            // (https://a.dev/x vs https://a.dev:443/x) key differently —
            // that under-dedups rather than colliding, which is the safe
            // direction to be wrong in.
            let portSuffix = url.port.map { ":\($0)" } ?? ""
            var key = "\(scheme)://\(host.lowercased())\(portSuffix)\(path)"
            if let query = url.query, !query.isEmpty { key += "?\(query)" }
            return Artifact(key: key, kind: .url, resolvedPath: nil, urlString: raw,
                            timestamp: candidate.timestamp)

        case .path(let raw):
            // An empty token names nothing. Without this guard it resolves
            // against cwd to cwd itself (a real, existing directory), which
            // would surface the project root as a drawer row. Reachable
            // beyond text scanning: TranscriptArtifactExtractor.fromToolUse
            // reads "file_path" straight off tool_use JSON with no
            // non-empty guard of its own, so a malformed transcript line
            // can hand this an empty string directly. This is the only
            // place that gets a vote, so the guard belongs here.
            guard !raw.isEmpty else { return nil }
            // A trailing `:12` is a line reference, not part of the name.
            let withoutLine = raw.replacingOccurrences(
                of: ":[0-9]+(:[0-9]+)?$", with: "", options: .regularExpression)
            let resolved = PathDetector.resolvePath(withoutLine, cwd: candidate.cwd)

            guard let path = firstExisting(resolved, fileManager: fileManager) else { return nil }
            guard !isNoise(path, cwd: candidate.cwd) else { return nil }

            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: path, isDirectory: &isDir)
            let kind: ArtifactKind = isDir.boolValue ? .folder : (isImage(path) ? .image : .file)
            return Artifact(key: path, kind: kind, resolvedPath: path, urlString: nil,
                            timestamp: candidate.timestamp)
        }
    }

    /// Paths that exist on disk and are still not artifacts.
    ///
    /// Added by the final whole-branch review, which ran the shipped code
    /// over the owner's three largest real transcripts and found the drawer
    /// dominated by navigational context rather than by anything Claude
    /// made. The existence filter cannot help here, because every one of
    /// these genuinely exists:
    ///
    /// - `/dev/*`: `/dev/null` appeared 346 times in one 52 MB session,
    ///   almost entirely from `2>/dev/null` inside Bash commands, and
    ///   `/dev/console` the same way. Tested on the RESOLVED path, not on
    ///   the raw token, so a relative `dev/null` under cwd is untouched and
    ///   an ordinary file whose name merely starts with "dev" is untouched
    ///   too (see testFileNamedDevIsNotDropped).
    /// - `/`: what `///` used to resolve to before the scanner stopped
    ///   emitting punctuation-only tokens. Belt and braces, and it also
    ///   covers a literal `/` arriving from a tool_use key.
    /// - the entry's own `cwd`: the project root, mentioned constantly (201
    ///   times in that same session) and never a product. A path equal to
    ///   cwd cannot be a folder Claude just created, since cwd already
    ///   existed before the session started, so nothing real is hidden.
    /// - the home directory: same argument, one level up.
    ///
    /// Both sides are standardized the same way `resolvePath` standardizes
    /// its output, otherwise a cwd carrying a trailing slash or an
    /// unresolved symlink would never compare equal. The incoming path
    /// needs it too, and not only in theory: measured on the owner's three
    /// largest transcripts, an ELLIPSIS in prose ("...") resolved to
    /// `<cwd>/...`, which does not exist, and then `firstExisting`'s
    /// trailing-dot retry turned it into `<cwd>/`, which does — so the
    /// project root appeared a SECOND time under a different dedup key.
    /// `TextArtifactScanner` now rejects "..." upstream, but tool_use keys
    /// reach this function with no scanner in front of them.
    private static func isNoise(_ path: String, cwd: String) -> Bool {
        if path.hasPrefix("/dev/") { return true }
        let normalized = (path as NSString).standardizingPath
        if normalized == "/" { return true }
        if normalized == (cwd as NSString).standardizingPath { return true }
        if normalized == (NSHomeDirectory() as NSString).standardizingPath { return true }
        return false
    }

    /// The path as resolved, else the same path with sentence-ending dots
    /// removed. Same two-attempt shape the Cmd+click handler already uses
    /// in TerminalContainerView, and the reason `trailingDotStripped`
    /// exists at all.
    private static func firstExisting(_ path: String, fileManager: FileManager) -> String? {
        if fileManager.fileExists(atPath: path) { return path }
        if let stripped = PathDetector.trailingDotStripped(path),
           fileManager.fileExists(atPath: stripped) { return stripped }
        return nil
    }
}
