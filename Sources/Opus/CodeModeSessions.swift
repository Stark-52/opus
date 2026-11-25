// CodeModeSessions — which conversations run in Claude Code's code mode.
//
// Code mode is switched on by one environment variable on the claude process.
// A conversation begun in code mode can only be continued in code mode, so a
// spawn that reopens one (a resume, a --continue) has to switch it back on.
// Opus remembers the conversations it started in code mode; one started
// elsewhere is recognised by its transcript, where code mode runs every tool
// call through the REPL tool.

import Foundation

struct CodeModeSessions {
    static let environmentVariable = "CLAUDE_CODE_EXPERIMENTAL_CODE_MODE"
    static let shared = CodeModeSessions()

    /// Enough for months of tabs; the oldest ids are dropped first.
    static let limit = 500
    /// How much of a transcript's end is read to recognise code mode.
    static let tailBytes: UInt64 = 256 * 1024

    private static let key = "opus.codeModeSessions"
    /// A tool call to the REPL tool, as the transcript's JSON writes it. The
    /// same words quoted inside a message are escaped (\"name\":\"REPL\") and
    /// do not match.
    private static let marker = Data("\"name\":\"REPL\"".utf8)

    let defaults: UserDefaults
    let projectsRoot: URL

    init(defaults: UserDefaults = .standard,
         projectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) {
        self.defaults = defaults
        self.projectsRoot = projectsRoot
    }

    /// Notes a conversation Opus starts in code mode.
    func remember(_ sessionId: String) {
        var ids = defaults.stringArray(forKey: Self.key) ?? []
        ids.removeAll { $0 == sessionId }
        ids.append(sessionId)
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
        defaults.set(ids, forKey: Self.key)
    }

    func remembers(_ sessionId: String) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(sessionId)
    }

    /// True when this conversation has to be reopened in code mode.
    func isCodeMode(_ sessionId: String) -> Bool {
        if remembers(sessionId) { return true }
        guard let file = transcript(for: sessionId) else { return false }
        return Self.transcriptUsesCodeMode(file)
    }

    /// Whether a spawn with this resume mode runs in code mode: never for a
    /// fresh session, and for a resumed or continued one exactly when that
    /// conversation began in code mode.
    func reopensInCodeMode(_ mode: OpusResumeMode, workingDirectory: String) -> Bool {
        switch mode {
        case .none:
            return false
        case .resume(let id):
            return isCodeMode(id)
        case .continueMostRecent:
            return ClaudeSessionLocator.mostRecentSessionId(for: workingDirectory, projectsRoot: projectsRoot)
                .map(isCodeMode) ?? false
        }
    }

    /// The transcript of a conversation, in whichever project it was held.
    func transcript(for sessionId: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return nil }
        return dirs.lazy
            .map { $0.appendingPathComponent(sessionId + ".jsonl") }
            .first { fm.fileExists(atPath: $0.path) }
    }

    static func transcriptUsesCodeMode(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return false }
        return data.range(of: marker) != nil
    }
}
