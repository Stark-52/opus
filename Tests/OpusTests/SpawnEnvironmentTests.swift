import XCTest
@testable import Opus

final class SpawnEnvironmentTests: XCTestCase {

    private func value(_ key: String, in env: [String]) -> String? {
        env.first { $0.hasPrefix("\(key)=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    func testEmptyBaseGetsTerminalIdentityAndSystemPath() {
        let env = SpawnEnvironment.make(base: [:])
        XCTAssertEqual(value("TERM", in: env), "xterm-256color")
        XCTAssertEqual(value("COLORTERM", in: env), "truecolor")
        XCTAssertEqual(value("LANG", in: env), "en_US.UTF-8")
        XCTAssertEqual(value("PATH", in: env), "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testBasePathKeptInFrontAndMissingSystemDirsAppended() {
        // A Dock-launched app can carry a partial PATH; a ~/.zshenv running
        // `brew shellenv` on an empty PATH produces exactly this shape. The
        // system dirs must ALWAYS end up present or `security`, `bash`, `mv`
        // vanish for the child claude (the 2026-08 login bug).
        let env = SpawnEnvironment.make(base: ["PATH": "/opt/homebrew/bin:/opt/homebrew/sbin"])
        XCTAssertEqual(
            value("PATH", in: env),
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        )
    }

    func testCompleteSystemPathIsUntouched() {
        let full = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let env = SpawnEnvironment.make(base: ["PATH": full])
        XCTAssertEqual(value("PATH", in: env), full)
    }

    func testBaseVariablesAreInherited() {
        let env = SpawnEnvironment.make(base: [
            "HOME": "/Users/test",
            "USER": "test",
            "TMPDIR": "/var/folders/xx/T/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        XCTAssertEqual(value("HOME", in: env), "/Users/test")
        XCTAssertEqual(value("USER", in: env), "test")
        XCTAssertEqual(value("TMPDIR", in: env), "/var/folders/xx/T/")
    }

    func testExistingLangIsPreserved() {
        let env = SpawnEnvironment.make(base: ["LANG": "fr_FR.UTF-8"])
        XCTAssertEqual(value("LANG", in: env), "fr_FR.UTF-8")
    }

    func testTermIsForcedEvenIfBaseHasOne() {
        // The app might inherit TERM=dumb when launched from a script.
        let env = SpawnEnvironment.make(base: ["TERM": "dumb"])
        XCTAssertEqual(value("TERM", in: env), "xterm-256color")
    }

    func testNoDuplicateKeys() {
        let env = SpawnEnvironment.make(base: ["PATH": "/usr/bin", "TERM": "dumb"])
        let keys = env.map { String($0.prefix(upTo: $0.firstIndex(of: "=") ?? $0.endIndex)) }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testClaudeSessionMarkersAreStripped() {
        let env = SpawnEnvironment.make(base: [
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "true",
            "CLAUDE_CODE_SESSION_ID": "abc",
            "CLAUDE_CODE_ENTRYPOINT": "cli",
            "CLAUDE_CODE_SSE_PORT": "1234",
            "CLAUDE_CODE_MESSAGING_SOCKET": "/tmp/x.sock",
            "CLAUDE_CODE_BRIDGE_SESSION_ID": "def",
            "CLAUDE_CODE_EXECPATH": "/usr/local/bin/claude",
            "CLAUDE_PID": "42",
            "CLAUDE_EFFORT": "xhigh",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        for marker in SpawnEnvironment.claudeSessionMarkers {
            XCTAssertFalse(env.contains { $0.hasPrefix("\(marker)=") },
                           "\(marker) must not leak into spawned sessions")
        }
    }

    func testUserClaudeConfigVarsSurvive() {
        // User CONFIG (not session markers) must pass through untouched.
        let env = SpawnEnvironment.make(base: [
            "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION": "1",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ])
        XCTAssertTrue(env.contains("CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=1"))
    }

    func testMarkerListCoversTheCriticalOnes() {
        for critical in ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION",
                         "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT"] {
            XCTAssertTrue(SpawnEnvironment.claudeSessionMarkers.contains(critical))
        }
    }
}
