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
            var key = "\(scheme)://\(host.lowercased())\(path)"
            if let query = url.query, !query.isEmpty { key += "?\(query)" }
            return Artifact(key: key, kind: .url, resolvedPath: nil, urlString: raw)

        case .path(let raw):
            // A trailing `:12` is a line reference, not part of the name.
            let withoutLine = raw.replacingOccurrences(
                of: ":[0-9]+(:[0-9]+)?$", with: "", options: .regularExpression)
            let resolved = PathDetector.resolvePath(withoutLine, cwd: candidate.cwd)

            guard let path = firstExisting(resolved, fileManager: fileManager) else { return nil }

            var isDir: ObjCBool = false
            _ = fileManager.fileExists(atPath: path, isDirectory: &isDir)
            let kind: ArtifactKind = isDir.boolValue ? .folder : (isImage(path) ? .image : .file)
            return Artifact(key: path, kind: kind, resolvedPath: path, urlString: nil)
        }
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
