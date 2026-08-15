// Artifact — a candidate the disk confirmed, or a URL that parsed.
//
// `key` is the deduplication identity and is NOT the display path: the
// same file cited with and without a `:12` line suffix, or as a relative
// and then an absolute path, is one artifact. For URLs the key normalises
// host case and a trailing slash but keeps the query, and keeps http and
// https apart because they are not necessarily the same resource.

import Foundation

public enum ArtifactKind: String, Equatable, Sendable {
    case file, folder, image, url
}

public struct Artifact: Equatable, Sendable {
    public let key: String
    public let kind: ArtifactKind
    /// Absolute, standardized. Nil for `.url`.
    public let resolvedPath: String?
    /// The REAL url, query string and any token intact. Nil for file kinds.
    /// Display goes through SecretRedactor at the view layer; opening and
    /// copying must use this value or the link stops working.
    public let urlString: String?

    public init(key: String, kind: ArtifactKind, resolvedPath: String?, urlString: String?) {
        self.key = key
        self.kind = kind
        self.resolvedPath = resolvedPath
        self.urlString = urlString
    }

    /// Filename, folder name, or host. The bold half of a row.
    public var displayName: String {
        if let path = resolvedPath { return (path as NSString).lastPathComponent }
        guard let urlString, let url = URL(string: urlString) else { return urlString ?? "" }
        return url.host ?? urlString
    }

    /// Parent directory, or the URL's path. The dim half of a row.
    public var displayDetail: String {
        if let path = resolvedPath { return (path as NSString).deletingLastPathComponent }
        guard let urlString, let url = URL(string: urlString) else { return "" }
        return url.path.isEmpty ? urlString : url.path
    }
}
