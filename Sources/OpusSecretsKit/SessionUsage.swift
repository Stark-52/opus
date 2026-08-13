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
#if canImport(Darwin)
import Darwin
#endif

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
        let url = fileURL(sessionID: sessionID)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // hasAny() already told the caller this session HAS recorded
            // usage (it only checks existence), so a read failure here is
            // not "nothing was ever substituted" — it is the redaction net
            // going dark for the rest of this session with no signal at
            // all, unless this warns. `record()` already warns on its own
            // failure to write; this is the read-side twin of that.
            if FileManager.default.fileExists(atPath: url.path) {
                Self.warn("cannot read the session file at \(url.path); the redaction net is off for the rest of this session")
            }
            return []
        }
        var seen = Set<String>()
        return text
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { SecretName.isValid($0) && seen.insert($0).inserted }
    }

    public func hasAny(sessionID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(sessionID: sessionID).path)
    }

    public func record(names newNames: [String], sessionID: String) {
        let valid = newNames.filter(SecretName.isValid)
        guard !valid.isEmpty else { return }

        ensureDirectory()

        // Append, never read-modify-write. Claude Code issues parallel tool
        // calls, so two PreToolUse hooks can record into the same session
        // file at the same time, each in its own short-lived process. A
        // read-merge-overwrite loses whichever name the other process wrote
        // between the read and the write, and a lost name here is a secret
        // hook-post will never redact. The recorded set only ever grows, so
        // appending and de-duplicating on read is correct without any lock.
        //
        // O_APPEND makes each write land at the true end of file atomically,
        // so two concurrent appends interleave as whole lines rather than
        // overwriting one another (verified: 200 concurrent appends produced
        // 200 distinct, uncorrupted lines). O_CREAT with mode 0600 means the
        // file is BORN owner-only, closing the window the previous
        // write-then-chmod left open on every session's first record.
        guard let data = (valid.joined(separator: "\n") + "\n").data(using: .utf8) else { return }
        let fd = open(fileURL(sessionID: sessionID).path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            // Nothing recorded means hook-post will not redact these secrets.
            // Nothing can be returned (the interface is void) and stdout
            // carries the hook's JSON protocol, so stderr is the only honest
            // channel — the same reasoning opus-attach uses.
            Self.warn("cannot open the session file (errno \(errno)); \(valid.count) secret name(s) unrecorded, redaction will be incomplete")
            return
        }
        defer { close(fd) }

        // write(2) may return a short count on ENOSPC or EDQUOT. Dropping the
        // tail would leave a line with no terminating newline, so the NEXT
        // append would merge into it and both names would be lost on read.
        // Loop to completion rather than trusting one call.
        var written = 0
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while written < raw.count {
                let n = write(fd, base + written, raw.count - written)
                if n > 0 { written += n; continue }
                if n < 0 && errno == EINTR { continue }
                break
            }
        }
        if written != data.count {
            Self.warn("short write recording secret names (\(written)/\(data.count) bytes); redaction may be incomplete")
        }
    }

    /// Diagnostics go to stderr, never stdout: this type runs inside Claude
    /// Code hooks whose stdout carries the JSON hook protocol, and anything
    /// written there would corrupt it. Same convention as opus-attach.
    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("opus-secrets: \(message)\n".utf8))
    }

    /// `createDirectory(withIntermediateDirectories:attributes:)` silently
    /// ignores `attributes` when the directory already exists (verified: a
    /// directory created at 0755 stayed 0755 after a second call requesting
    /// 0700), so the mode is set unconditionally afterwards.
    private func ensureDirectory() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
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
