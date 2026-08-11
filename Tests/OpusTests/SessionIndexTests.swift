import XCTest
@testable import Opus

final class SessionIndexTests: XCTestCase {
    private let sid = "11111111-1111-1111-1111-111111111111"
    private let now = Date()

    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    // MARK: parseSummary

    func testStringContent_extractsTitleAndCwd() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj","gitBranch":"main"}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"fix the login bug"}}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.cwd, "/Users/dev/proj")
        XCTAssertEqual(s?.title, "fix the login bug")
        XCTAssertEqual(s?.sessionId, sid)
        XCTAssertEqual(s?.mtime, now)
    }

    func testArrayOfBlocksContent_concatenatesTextFields() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":[{"type":"text","text":"first part"},{"type":"image","source":"..."},{"type":"text","text":"second part"}]}}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title, "first part second part")
    }

    func testMetaFirstRecordSkipped_usesNextRealUserRecord() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>ignore me</local-command-caveat>"}}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"real prompt text"}}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title, "real prompt text")
    }

    func testMissingCwd_returnsNil() {
        let head = data([
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"no cwd anywhere"}}"#,
        ])
        XCTAssertNil(SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now))
    }

    func testTitleTruncatedTo80Chars() {
        let long = String(repeating: "x", count: 200)
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"\#(long)"}}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title.count, 80)
        XCTAssertEqual(s?.title, String(long.prefix(80)))
    }

    func testGitBranchPresent() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj","gitBranch":"feature/x"}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.gitBranch, "feature/x")
    }

    func testGitBranchAbsent_isNil() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertNil(s?.gitBranch)
    }

    func testNoUserRecord_fallsBackToCwdLastPathComponent() {
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/Documents/GitHub/ClaudeUltra"}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title, "ClaudeUltra")
    }

    func testAiTitleRecordPreferredOverFirstUserText() {
        // Real shape: a standalone {"type":"ai-title","aiTitle":"..."} record,
        // NOT nested under message.content. Present anywhere in the scanned
        // head, it wins over the first-user-message fallback.
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"raw first prompt"}}"#,
            #"{"type":"ai-title","aiTitle":"Fix login regression"}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title, "Fix login regression")
    }

    // MARK: scan

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-sessionindex-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeSession(
        project: String,
        id: String,
        cwd: String,
        age: TimeInterval
    ) throws {
        let dir = root.appendingPathComponent(project)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(id).jsonl")
        let line = #"{"type":"attachment","cwd":"\#(cwd)"}"#
        try line.write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)],
            ofItemAtPath: f.path
        )
    }

    func testScan_sortsByMtimeDescendingAcrossProjectDirsAndAppliesLimit() throws {
        try writeSession(project: "-Users-dev-projA", id: "11111111-1111-1111-1111-111111111111", cwd: "/Users/dev/projA", age: 3600)
        try writeSession(project: "-Users-dev-projA", id: "22222222-2222-2222-2222-222222222222", cwd: "/Users/dev/projA", age: 60)
        try writeSession(project: "-Users-dev-projB", id: "33333333-3333-3333-3333-333333333333", cwd: "/Users/dev/projB", age: 7200)
        try writeSession(project: "-Users-dev-projB", id: "44444444-4444-4444-4444-444444444444", cwd: "/Users/dev/projB", age: 120)

        let all = SessionIndex.scan(projectsDir: root, limit: 40)
        XCTAssertEqual(all.map(\.sessionId), [
            "22222222-2222-2222-2222-222222222222",
            "44444444-4444-4444-4444-444444444444",
            "11111111-1111-1111-1111-111111111111",
            "33333333-3333-3333-3333-333333333333",
        ])

        let limited = SessionIndex.scan(projectsDir: root, limit: 2)
        XCTAssertEqual(limited.map(\.sessionId), [
            "22222222-2222-2222-2222-222222222222",
            "44444444-4444-4444-4444-444444444444",
        ])
    }

    func testScan_ignoresNonUUIDFilenames() throws {
        let dir = root.appendingPathComponent("-Users-dev-proj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rogue = dir.appendingPathComponent("not-a-uuid.jsonl")
        try #"{"type":"attachment","cwd":"/Users/dev/proj"}"#.write(to: rogue, atomically: true, encoding: .utf8)
        try writeSession(project: "-Users-dev-proj", id: "55555555-5555-5555-5555-555555555555", cwd: "/Users/dev/proj", age: 60)

        let results = SessionIndex.scan(projectsDir: root, limit: 40)
        XCTAssertEqual(results.map(\.sessionId), ["55555555-5555-5555-5555-555555555555"])
    }

    func testScan_emptyProjectsDir_returnsEmpty() {
        XCTAssertEqual(SessionIndex.scan(projectsDir: root, limit: 40), [])
    }
}
