// SessionUsage — which secrets were substituted into which session.
//
// This is what keeps hook-post both cheap and narrow. The redaction set is
// not "every secret in the Keychain", it is "the secrets this session has
// actually used", because a secret that was never substituted cannot
// appear in any output. The common case is that the file does not exist at
// all, which is one stat() and an immediate exit.
//
// NAMES only, never values. Writing values here would put plaintext
// secrets on disk to defend against plaintext secrets reaching a
// transcript, which would be a bad trade.

import Foundation

public struct SessionUsage {
    private let directory: URL

    public static var defaultDirectory: URL {
        let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent("opus-secrets", isDirectory: true)
    }

    public init(directory: URL = SessionUsage.defaultDirectory) {
        self.directory = directory
    }

    /// A session id arrives from hook stdin, so it is untrusted input used
    /// to build a path. Everything outside the safe set is stripped rather
    /// than escaped: no separator survives, so no file can be written
    /// outside `directory`.
    private func fileURL(sessionID: String) -> URL {
        let safe = String(sessionID.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let name = safe.isEmpty ? "unknown" : String(safe.prefix(128))
        return directory.appendingPathComponent("\(name).names")
    }

    public func names(sessionID: String) -> [String] {
        guard let text = try? String(contentsOf: fileURL(sessionID: sessionID), encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .map(String.init)
            .filter(SecretName.isValid)
    }

    public func hasAny(sessionID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(sessionID: sessionID).path)
    }

    public func record(names newNames: [String], sessionID: String) {
        let valid = newNames.filter(SecretName.isValid)
        guard !valid.isEmpty else { return }

        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let url = fileURL(sessionID: sessionID)
        var merged = Set(names(sessionID: sessionID))
        merged.formUnion(valid)
        let body = merged.sorted().joined(separator: "\n") + "\n"

        guard let data = body.data(using: .utf8) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func prune(olderThan age: TimeInterval, now: Date = Date()) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            if now.timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
