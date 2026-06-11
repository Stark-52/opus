import XCTest
@testable import Opus

final class ClaudeSessionLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeProject(_ dirName: String, sessions: [(id: String, age: TimeInterval)]) throws {
        let dir = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in sessions {
            let f = dir.appendingPathComponent("\(s.id).jsonl")
            try "{}".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -s.age)],
                ofItemAtPath: f.path
            )
        }
    }

    func testEncodesSlashesToDashes() {
        let candidates = ClaudeSessionLocator.projectDirNameCandidates(
            for: "/Users/andy/Documents/GitHub/ClaudeUltra")
        XCTAssertEqual(candidates.first, "-Users-andy-Documents-GitHub-ClaudeUltra")
    }

    func testLegacyEncodingReplacesDots() {
        let candidates = ClaudeSessionLocator.projectDirNameCandidates(
            for: "/Users/andy/.claude/worktrees/x")
        XCTAssertEqual(candidates, [
            "-Users-andy-.claude-worktrees-x",   // current: dots kept
            "-Users-andy--claude-worktrees-x"    // legacy: dots → dashes
        ])
    }

    func testNoDuplicateCandidatesWhenPathHasNoDots() {
        let candidates = ClaudeSessionLocator.projectDirNameCandidates(for: "/Users/andy/proj")
        XCTAssertEqual(candidates, ["-Users-andy-proj"])
    }

    func testPicksMostRecentSession() throws {
        try makeProject("-Users-andy-proj", sessions: [
            (id: "11111111-aaaa-bbbb-cccc-000000000001", age: 3600),
            (id: "22222222-aaaa-bbbb-cccc-000000000002", age: 60),
            (id: "33333333-aaaa-bbbb-cccc-000000000003", age: 7200)
        ])
        let id = ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/proj", projectsRoot: root)
        XCTAssertEqual(id, "22222222-aaaa-bbbb-cccc-000000000002")
    }

    func testFallsBackToLegacyDirName() throws {
        try makeProject("-Users-andy--claude-x", sessions: [(id: "aaaa", age: 60)])
        let id = ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/.claude/x", projectsRoot: root)
        XCTAssertEqual(id, "aaaa")
    }

    func testReturnsNilWhenNoProjectDir() {
        XCTAssertNil(ClaudeSessionLocator.mostRecentSessionId(for: "/nope/never", projectsRoot: root))
    }

    func testReturnsNilWhenDirHasNoSessions() throws {
        try makeProject("-Users-andy-empty", sessions: [])
        XCTAssertNil(ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/empty", projectsRoot: root))
    }
}
