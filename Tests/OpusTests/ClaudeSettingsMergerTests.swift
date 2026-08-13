import XCTest
@testable import OpusSecretsKit

final class ClaudeSettingsMergerTests: XCTestCase {
    private var dir: URL!
    private let binary = "/Users/x/.local/bin/opus-secrets"

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-settings-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func merge(_ existing: [String: Any]) -> [String: Any] {
        ClaudeSettingsMerger.merged(into: existing, binaryPath: binary, timeoutSeconds: 3)
    }

    private func commands(_ root: [String: Any], _ event: String) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [String] in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    func testAddsAllThreeEventsToAnEmptySettingsObject() {
        let out = merge([:])
        XCTAssertEqual(commands(out, "PreToolUse"), ["\(binary) hook-pre"])
        XCTAssertEqual(commands(out, "PostToolUse"), ["\(binary) hook-post"])
        XCTAssertEqual(commands(out, "SessionStart"), ["\(binary) hook-session"])
    }

    func testMatchersFollowTheSpec() throws {
        let hooks = try XCTUnwrap(merge([:])["hooks"] as? [String: Any])
        let pre = try XCTUnwrap((hooks["PreToolUse"] as? [[String: Any]])?.first)
        let post = try XCTUnwrap((hooks["PostToolUse"] as? [[String: Any]])?.first)
        let session = try XCTUnwrap((hooks["SessionStart"] as? [[String: Any]])?.first)
        XCTAssertEqual(pre["matcher"] as? String, "Bash", "substitution is Bash-only")
        XCTAssertEqual(post["matcher"] as? String, "*", "redaction covers every tool")
        XCTAssertNil(session["matcher"], "SessionStart takes no matcher")
    }

    func testPreservesUnrelatedTopLevelKeys() {
        let out = merge(["model": "opus", "permissions": ["allow": ["Bash(ls:*)"]]])
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertNotNil(out["permissions"])
    }

    func testPreservesTheUsersOwnHooksOnTheSameEvent() {
        let existing: [String: Any] = ["hooks": [
            "PreToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "/my/own/linter"]]]]
        ]]
        let out = merge(existing)
        XCTAssertEqual(commands(out, "PreToolUse"), ["/my/own/linter", "\(binary) hook-pre"])
    }

    func testMergingTwiceDoesNotDuplicate() {
        let once = merge([:])
        let twice = merge(once)
        XCTAssertEqual(commands(twice, "PreToolUse"), ["\(binary) hook-pre"])
        XCTAssertEqual(commands(twice, "PostToolUse"), ["\(binary) hook-post"])
    }

    func testAStaleBinaryPathIsReplacedNotAccumulated() {
        let stale = ClaudeSettingsMerger.merged(into: [:], binaryPath: "/old/opus-secrets", timeoutSeconds: 3)
        let fresh = merge(stale)
        XCTAssertEqual(commands(fresh, "PreToolUse"), ["\(binary) hook-pre"],
                       "entries are identified by the command marker, so a moved binary is updated in place")
    }

    func testNoUnknownTopLevelKeyIsIntroduced() {
        let out = merge([:])
        XCTAssertEqual(Set(out.keys), ["hooks"],
                       "a version marker in settings.json would trip Claude Code's own validation")
    }

    func testApplyWritesCreatesABackupAndIsIdempotent() throws {
        let settings = dir.appendingPathComponent("settings.json")
        let backup = dir.appendingPathComponent("settings.json.opus-bak")
        try Data("{\"model\":\"opus\"}".utf8).write(to: settings)

        let firstChanged = try ClaudeSettingsMerger.apply(
            settingsURL: settings, backupURL: backup, binaryPath: binary, timeoutSeconds: 3
        )
        XCTAssertTrue(firstChanged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{\"model\":\"opus\"}")

        let secondChanged = try ClaudeSettingsMerger.apply(
            settingsURL: settings, backupURL: backup, binaryPath: binary, timeoutSeconds: 3
        )
        XCTAssertFalse(secondChanged, "an unchanged merge must not rewrite the file")
    }

    func testApplyCreatesTheFileWhenItDoesNotExist() throws {
        let settings = dir.appendingPathComponent("absent.json")
        let backup = dir.appendingPathComponent("absent.json.opus-bak")
        XCTAssertTrue(try ClaudeSettingsMerger.apply(
            settingsURL: settings, backupURL: backup, binaryPath: binary, timeoutSeconds: 3
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path), "nothing existed, so nothing to back up")
    }

    func testApplyRefusesToTouchAMalformedFile() throws {
        let settings = dir.appendingPathComponent("broken.json")
        let backup = dir.appendingPathComponent("broken.json.opus-bak")
        let original = "{ this is not json"
        try Data(original.utf8).write(to: settings)

        XCTAssertThrowsError(try ClaudeSettingsMerger.apply(
            settingsURL: settings, backupURL: backup, binaryPath: binary, timeoutSeconds: 3
        ))
        XCTAssertEqual(try String(contentsOf: settings, encoding: .utf8), original,
                       "never clobber a settings file we cannot parse")
    }
}
