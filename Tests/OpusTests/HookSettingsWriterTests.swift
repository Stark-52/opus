import XCTest
@testable import Opus

/// HookSettingsWriter's disk-touching entry point (ensureSettingsFile) is
/// exercised against an isolated temp directory in every test here — never
/// the real ~/Library/Application Support/Opus — so these tests can't leave
/// stray state on the machine they run on or race a real Opus.app instance.
final class HookSettingsWriterTests: XCTestCase {
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-hook-settings-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func readJSON(at path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testFileIsCreatedAndDecodableWithAllSixEvents() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: "/usr/local/bin/opus-attach")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let json = try readJSON(at: path)
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionStart"] {
            XCTAssertNotNil(hooks[event], "missing hook registration for \(event)")
        }
        XCTAssertEqual(hooks.count, 6)
    }

    func testMatcherPresentOnlyForToolEvents() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: "/usr/local/bin/opus-attach")
        let hooks = try XCTUnwrap(try readJSON(at: path)["hooks"] as? [String: Any])

        func firstEntry(_ event: String) throws -> [String: Any] {
            let arr = try XCTUnwrap(hooks[event] as? [[String: Any]])
            return try XCTUnwrap(arr.first)
        }
        XCTAssertEqual(try firstEntry("PreToolUse")["matcher"] as? String, "*")
        XCTAssertEqual(try firstEntry("PostToolUse")["matcher"] as? String, "*")
        XCTAssertNil(try firstEntry("UserPromptSubmit")["matcher"])
        XCTAssertNil(try firstEntry("Notification")["matcher"])
        XCTAssertNil(try firstEntry("Stop")["matcher"])
        XCTAssertNil(try firstEntry("SessionStart")["matcher"])
    }

    func testCommandUsesAbsoluteSingleQuotedBinaryPathAndTimeoutThree() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryPath = "/Applications/Opus.app/Contents/MacOS/opus-attach"

        let path = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: binaryPath)
        let hooks = try XCTUnwrap(try readJSON(at: path)["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["UserPromptSubmit"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        let innerHooks = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
        let hook = try XCTUnwrap(innerHooks.first)

        let command = try XCTUnwrap(hook["command"] as? String)
        XCTAssertEqual(command, "'\(binaryPath)' event UserPromptSubmit")
        XCTAssertEqual(hook["type"] as? String, "command")
        XCTAssertEqual(hook["timeout"] as? Int, 3)
    }

    func testEachEventCommandNamesItself() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryPath = "/usr/local/bin/opus-attach"

        let path = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: binaryPath)
        let hooks = try XCTUnwrap(try readJSON(at: path)["hooks"] as? [String: Any])

        for eventName in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification", "Stop", "SessionStart"] {
            let entries = try XCTUnwrap(hooks[eventName] as? [[String: Any]])
            let entry = try XCTUnwrap(entries.first)
            let innerHooks = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
            let hook = try XCTUnwrap(innerHooks.first)
            let command = try XCTUnwrap(hook["command"] as? String)
            XCTAssertEqual(command, "'\(binaryPath)' event \(eventName)")
        }
    }

    func testIdempotentWriteDoesNotChangeMtime() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let binaryPath = "/usr/local/bin/opus-attach"

        let path1 = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: binaryPath)
        let mtime1 = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path1)[.modificationDate] as? Date
        )

        // Sub-second sleep: APFS mtimes have sub-second resolution, so a
        // broken "always rewrite" implementation would show a different
        // value even after a very short pause.
        Thread.sleep(forTimeInterval: 0.05)

        let path2 = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: binaryPath)
        let mtime2 = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: path2)[.modificationDate] as? Date
        )

        XCTAssertEqual(path1, path2)
        XCTAssertEqual(mtime1, mtime2)
    }

    func testChangedBinaryPathRewritesContent() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: "/usr/local/bin/opus-attach")
        let path = HookSettingsWriter.ensureSettingsFile(directory: dir, binaryPath: "/opt/homebrew/bin/opus-attach")

        let raw = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        XCTAssertTrue(raw.contains("/opt/homebrew/bin/opus-attach"))
        XCTAssertFalse(raw.contains("/usr/local/bin/opus-attach"))
    }

    func testIntermediateDirectoriesAreCreated() throws {
        let parent = makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appendingPathComponent("nested/does/not/exist", isDirectory: true)

        let path = HookSettingsWriter.ensureSettingsFile(directory: nested, binaryPath: "/usr/local/bin/opus-attach")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    // MARK: Pure JSON builder — no disk access.

    func testSettingsJSONDataIsDeterministic() {
        let a = HookSettingsWriter.settingsJSONData(binaryPath: "/usr/local/bin/opus-attach")
        let b = HookSettingsWriter.settingsJSONData(binaryPath: "/usr/local/bin/opus-attach")
        XCTAssertEqual(a, b)
    }

    func testSettingsJSONDataEscapesEmbeddedSingleQuote() throws {
        // A path containing a single quote must not break the shell-form
        // command it's embedded in — the '\''  idiom must round-trip through
        // JSON correctly as well.
        let data = HookSettingsWriter.settingsJSONData(binaryPath: "/tmp/o'pus/opus-attach")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try XCTUnwrap(json["hooks"] as? [String: Any])
        let entries = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        let innerHooks = try XCTUnwrap(entry["hooks"] as? [[String: Any]])
        let hook = try XCTUnwrap(innerHooks.first)
        let command = try XCTUnwrap(hook["command"] as? String)
        XCTAssertEqual(command, "'/tmp/o'\\''pus/opus-attach' event Stop")
    }

    // MARK: composeSpawnCommand's injected flag reads this directly.

    func testEscapedSettingsPathForShellIsSingleQuotedAndPointsAtOpusHooksJSON() {
        let quoted = HookSettingsWriter.escapedSettingsPathForShell
        XCTAssertTrue(quoted.hasPrefix("'"))
        XCTAssertTrue(quoted.hasSuffix("'"))
        XCTAssertTrue(quoted.contains("opus-hooks.json"))
        XCTAssertTrue(quoted.contains("Application Support"))
    }
}
