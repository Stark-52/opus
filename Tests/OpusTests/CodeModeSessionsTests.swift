import XCTest
@testable import Opus

/// A conversation begun in code mode can only go on in code mode: Opus has to
/// know which ones were, from its own record or from the transcript.
final class CodeModeSessionsTests: XCTestCase {
    private let suite = "CodeModeSessionsTests"
    private var defaults: UserDefaults!
    private var root: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("codemode-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("-proj"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var sessions: CodeModeSessions { CodeModeSessions(defaults: defaults, projectsRoot: root) }

    private func transcript(_ id: String, _ lines: [String], modified: Date = Date()) {
        let file = root.appendingPathComponent("-proj/\(id).jsonl")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private let replCall = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_1","name":"REPL","input":{"code":"1"}}]}}"#
    private let bashCall = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"ls"}}]}}"#

    func testARememberedConversationIsCodeMode() {
        sessions.remember("a")
        XCTAssertTrue(sessions.isCodeMode("a"))
        XCTAssertFalse(sessions.isCodeMode("b"))
    }

    func testOnlyTheMostRecentAreKept() {
        for index in 0..<(CodeModeSessions.limit + 3) { sessions.remember("id-\(index)") }
        XCTAssertFalse(sessions.remembers("id-0"))
        XCTAssertFalse(sessions.remembers("id-2"))
        XCTAssertTrue(sessions.remembers("id-3"))
        XCTAssertTrue(sessions.remembers("id-\(CodeModeSessions.limit + 2)"))
    }

    func testATranscriptThatCallsTheReplToolIsCodeMode() {
        let id = UUID().uuidString.lowercased()
        transcript(id, [#"{"type":"user","message":{"content":"hello"}}"#, replCall])
        XCTAssertTrue(sessions.isCodeMode(id))
    }

    func testAPlainTranscriptIsNot() {
        let id = UUID().uuidString.lowercased()
        transcript(id, [bashCall])
        XCTAssertFalse(sessions.isCodeMode(id))
    }

    func testTheToolNameQuotedInAMessageDoesNotCount() {
        let id = UUID().uuidString.lowercased()
        transcript(id, [#"{"type":"user","message":{"content":"{\"name\":\"REPL\"}"}}"#, bashCall])
        XCTAssertFalse(sessions.isCodeMode(id))
    }

    func testAFreshSessionIsNeverCodeMode() {
        sessions.remember("a")
        XCTAssertFalse(sessions.reopensInCodeMode(.none, workingDirectory: "/proj"))
    }

    func testAResumeFollowsTheConversation() {
        sessions.remember("a")
        XCTAssertTrue(sessions.reopensInCodeMode(.resume(sessionId: "a"), workingDirectory: "/proj"))
        XCTAssertFalse(sessions.reopensInCodeMode(.resume(sessionId: "b"), workingDirectory: "/proj"))
    }

    func testAContinueFollowsTheMostRecentConversation() {
        let older = UUID().uuidString.lowercased()
        let newer = UUID().uuidString.lowercased()
        transcript(older, [bashCall], modified: Date(timeIntervalSinceNow: -600))
        transcript(newer, [replCall])
        XCTAssertTrue(sessions.reopensInCodeMode(.continueMostRecent, workingDirectory: "/proj"))
        transcript(older, [bashCall])   // now the most recent one is plain
        XCTAssertFalse(sessions.reopensInCodeMode(.continueMostRecent, workingDirectory: "/proj"))
    }
}
