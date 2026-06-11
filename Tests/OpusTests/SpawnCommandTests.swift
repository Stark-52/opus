import XCTest
@testable import Opus

final class SpawnCommandTests: XCTestCase {
    private let cwd = "/Users/test/Project"
    private let prefix = "cd \"/Users/test/Project\" && "

    func testClaudeDefaultNoFlags() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, prefix + "command claude")
    }

    func testClaudeSkipPermissions() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .none
        )
        XCTAssertEqual(cmd, prefix + "command claude --dangerously-skip-permissions")
    }

    func testClaudeContinue() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .continueMostRecent
        )
        XCTAssertEqual(cmd, prefix + "command claude --continue")
    }

    func testClaudeSkipAndResumeById() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .resume(sessionId: "abc-123")
        )
        XCTAssertEqual(cmd, prefix + "command claude --dangerously-skip-permissions --resume abc-123")
    }

    func testShellNeverGetsFlags() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .shell, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .continueMostRecent
        )
        XCTAssertEqual(cmd, prefix + "exec /bin/zsh -i")
    }

    func testCustomNeverGetsFlags() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .custom, customCommand: "tmux attach", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .continueMostRecent
        )
        XCTAssertEqual(cmd, prefix + "tmux attach")
    }

    func testEmptyCustomFallsBackToPlainClaude() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .custom, customCommand: "  ", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .none
        )
        // The empty-custom fallback stays flag-free: flags are a .claude-preset feature.
        XCTAssertEqual(cmd, prefix + "command claude")
    }
}
