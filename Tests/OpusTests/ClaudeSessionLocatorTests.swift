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

    func testDottedPathYieldsBothEncodings() {
        let candidates = ClaudeSessionLocator.projectDirNameCandidates(
            for: "/Users/andy/.claude/worktrees/x")
        XCTAssertEqual(candidates, [
            "-Users-andy--claude-worktrees-x",   // current: all non-alnum → dash
            "-Users-andy-.claude-worktrees-x"    // older: dots kept
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

    func testFallsBackToOlderDotKeepingDirName() throws {
        // Only the older dot-keeping encoding exists on disk; lookup must still find it
        // (second candidate: "-Users-andy-.claude-x").
        try makeProject("-Users-andy-.claude-x", sessions: [(id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", age: 60)])
        let id = ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/.claude/x", projectsRoot: root)
        XCTAssertEqual(id, "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    }

    func testRejectsNonUuidFilenames() throws {
        // The non-UUID file is newer; we must still return the UUID-named one.
        // (Shell-injection chars like ";" are not valid macOS filenames, so we
        // use a plain non-UUID string to represent any rogue filename.)
        try makeProject("-Users-andy-proj2", sessions: [
            (id: "not-a-uuid", age: 60),
            (id: "44444444-aaaa-bbbb-cccc-000000000004", age: 3600)
        ])
        let id = ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/proj2", projectsRoot: root)
        XCTAssertEqual(id, "44444444-aaaa-bbbb-cccc-000000000004")
    }

    func testCurrentEncodingWinsOverOlder() throws {
        // All-dash dir (current encoding) must be preferred over dot-keeping dir (older).
        try makeProject("-Users-andy--claude-y", sessions: [
            (id: "55555555-aaaa-bbbb-cccc-000000000005", age: 60)
        ])
        try makeProject("-Users-andy-.claude-y", sessions: [
            (id: "66666666-aaaa-bbbb-cccc-000000000006", age: 60)
        ])
        let id = ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/.claude/y", projectsRoot: root)
        XCTAssertEqual(id, "55555555-aaaa-bbbb-cccc-000000000005")
    }

    func testReturnsNilWhenNoProjectDir() {
        XCTAssertNil(ClaudeSessionLocator.mostRecentSessionId(for: "/nope/never", projectsRoot: root))
    }

    func testReturnsNilWhenDirHasNoSessions() throws {
        try makeProject("-Users-andy-empty", sessions: [])
        XCTAssertNil(ClaudeSessionLocator.mostRecentSessionId(for: "/Users/andy/empty", projectsRoot: root))
    }
}
