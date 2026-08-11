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

    func testTruncatedTrailingLine_headCutoffMidRecord_doesNotCrashOrMisparse() {
        // Simulates the real 16KB cutoff landing mid-record: two well-formed
        // lines, then a trailing fragment with no closing brace and no
        // terminating newline (exactly what handle.readData(ofLength:) hands
        // parseSummary when the budget runs out mid-line).
        var head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj","gitBranch":"main"}"#,
            #"{"type":"user","isMeta":false,"message":{"role":"user","content":"first well-formed prompt"}}"#,
        ])
        head.append(Data(#"\#n{"type":"user","isMeta":false,"message":{"role":"user","content":"trunc"#.utf8))
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.cwd, "/Users/dev/proj")
        XCTAssertEqual(s?.gitBranch, "main")
        XCTAssertEqual(s?.title, "first well-formed prompt")
    }

    func testUserRecordWithNoIsMetaKeyAtAll_treatedAsRealUserMessage() {
        // The common real shape: ordinary user records simply omit "isMeta"
        // entirely (only the synthetic caveat wrapper sets it to true) — must
        // NOT be treated as meta just because the key is absent.
        let head = data([
            #"{"type":"attachment","cwd":"/Users/dev/proj"}"#,
            #"{"type":"user","message":{"role":"user","content":"real prompt, no isMeta key at all"}}"#,
        ])
        let s = SessionIndex.parseSummary(jsonlHead: head, sessionId: sid, mtime: now)
        XCTAssertEqual(s?.title, "real prompt, no isMeta key at all")
    }

    // MARK: latestAiTitle

    func testLatestAiTitle_multipleRecords_lastWins() {
        let tail = data([
            "garbage-partial-line-not-json",   // simulated truncated seek-boundary fragment
            #"{"type":"ai-title","aiTitle":"First Title"}"#,
            #"{"type":"assistant","text":"unrelated"}"#,
            #"{"type":"ai-title","aiTitle":"Second Title"}"#,
        ])
        XCTAssertEqual(SessionIndex.latestAiTitle(jsonlTail: tail), "Second Title")
    }

    func testLatestAiTitle_firstLineDroppedUnconditionally_evenWhenWellFormed() {
        // If the seek offset happens to land exactly on a newline, the
        // "first line" could itself be a perfectly valid, complete ai-title
        // record. It must still be dropped unconditionally (the tail parser
        // can't distinguish a lucky boundary from a truncated one) — so with
        // no OTHER ai-title record present, the correct result is nil, even
        // though a naive parse of the whole buffer would have found one.
        let tail = data([
            #"{"type":"ai-title","aiTitle":"Should Never Win"}"#,
            #"{"type":"assistant","text":"unrelated, no ai-title here"}"#,
        ])
        XCTAssertNil(SessionIndex.latestAiTitle(jsonlTail: tail))
    }

    func testLatestAiTitle_noAiTitleRecordsPresent_returnsNil() {
        let tail = data([
            "garbage-partial-first-line",
            #"{"type":"assistant","text":"hello"}"#,
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
        ])
        XCTAssertNil(SessionIndex.latestAiTitle(jsonlTail: tail))
    }

    func testLatestAiTitle_noNewlineAtAllInTail_returnsNil() {
        XCTAssertNil(SessionIndex.latestAiTitle(jsonlTail: Data("no newline anywhere in here".utf8)))
    }

    func testLatestAiTitle_truncatedTo80Chars() {
        let long = String(repeating: "y", count: 200)
        let tail = data([
            "garbage-first-line",
            #"{"type":"ai-title","aiTitle":"\#(long)"}"#,
        ])
        let title = SessionIndex.latestAiTitle(jsonlTail: tail)
        XCTAssertEqual(title?.count, 80)
        XCTAssertEqual(title, String(long.prefix(80)))
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

    func testScan_largeFile_tailReadSurfacesLateAiTitle() throws {
        // End-to-end wiring check for the tail read added in Fix round 1:
        // an ai-title record placed past the 16KB head budget (but inside
        // the 40KB tail budget) must still surface as the summary's title.
        let dir = root.appendingPathComponent("-Users-dev-bigproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "66666666-6666-6666-6666-666666666666"
        let f = dir.appendingPathComponent("\(id).jsonl")

        var lines = [#"{"type":"attachment","cwd":"/Users/dev/bigproj","gitBranch":"main"}"#]
        let filler = String(repeating: "z", count: 200)
        for _ in 0..<150 {
            lines.append(#"{"type":"assistant","text":"\#(filler)"}"#)
        }
        lines.append(#"{"type":"ai-title","aiTitle":"Late title from the tail"}"#)
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: f, atomically: true, encoding: .utf8)

        // Precondition: big enough to trigger the tail read, small enough
        // that the whole file fits in one 40KB tail read (keeps the test's
        // math simple/robust rather than pinning an exact byte offset).
        XCTAssertGreaterThan(content.utf8.count, SessionIndex.headBudgetBytes)
        XCTAssertLessThan(content.utf8.count, SessionIndex.tailBudgetBytes)

        let results = SessionIndex.scan(projectsDir: root, limit: 40)
        XCTAssertEqual(results.first?.sessionId, id)
        XCTAssertEqual(results.first?.title, "Late title from the tail")
    }
}
