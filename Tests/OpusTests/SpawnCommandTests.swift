import XCTest
@testable import Opus

final class SpawnCommandTests: XCTestCase {
    private let cwd = "/Users/test/Project"
    private let prefix = "cd \"/Users/test/Project\" && "
    // The .claude preset always appends --settings pointing at Opus's
    // injected hooks file (Lot 3, Task 1 — the claude cockpit event bus).
    // Built against the SAME computed value composeSpawnCommand uses, not a
    // hardcoded path, since the path is machine-dependent
    // (~/Library/Application Support/...).
    private let settingsFlag = " --settings " + HookSettingsWriter.escapedSettingsPathForShell

    func testClaudeDefaultNoFlags() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, prefix + "command claude" + settingsFlag)
    }

    func testClaudeSkipPermissions() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .none
        )
        XCTAssertEqual(cmd, prefix + "command claude --dangerously-skip-permissions" + settingsFlag)
    }

    func testClaudeContinue() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .continueMostRecent
        )
        XCTAssertEqual(cmd, prefix + "command claude --continue" + settingsFlag)
    }

    func testClaudeSkipAndResumeById() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .resume(sessionId: "abc-123")
        )
        XCTAssertEqual(cmd, prefix + "command claude --dangerously-skip-permissions --resume abc-123" + settingsFlag)
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

    func testCwdWithDoubleQuoteIsEscaped() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "",
            workingDirectory: "/Users/test/Pro\"ject",
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, "cd \"/Users/test/Pro\\\"ject\" && command claude" + settingsFlag)
    }

    func testCwdWithDollarIsEscaped() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "",
            workingDirectory: "/Users/test/pro$ject",
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, "cd \"/Users/test/pro\\$ject\" && command claude" + settingsFlag)
    }

    func testCwdWithBacktickIsEscaped() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "",
            workingDirectory: "/Users/test/pro`ject",
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, "cd \"/Users/test/pro\\`ject\" && command claude" + settingsFlag)
    }

    func testCwdWithBackslashIsEscaped() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "",
            workingDirectory: "/Users/test/pro\\ject",
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertEqual(cmd, "cd \"/Users/test/pro\\\\ject\" && command claude" + settingsFlag)
    }

    func testPermissionModePlanAddsFlag() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none, permissionMode: .plan
        )
        XCTAssertEqual(cmd, prefix + "command claude --permission-mode plan" + settingsFlag)
    }
    func testSkipPermissionsWinsOverPermissionMode() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: true, resumeMode: .none, permissionMode: .acceptEdits
        )
        XCTAssertEqual(cmd, prefix + "command claude --dangerously-skip-permissions" + settingsFlag)
    }
    func testStandardModeAddsNothing() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none, permissionMode: .standard
        )
        XCTAssertEqual(cmd, prefix + "command claude" + settingsFlag)
    }

    // MARK: --settings injection scope — .claude only.

    func testSettingsFlagPresentForClaudePreset() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertTrue(cmd.contains("--settings"))
        XCTAssertTrue(cmd.contains("opus-hooks.json"))
    }

    func testSettingsFlagAbsentForShellPreset() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .shell, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertFalse(cmd.contains("--settings"))
    }

    func testSettingsFlagAbsentForCustomPreset() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .custom, customCommand: "tmux attach", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertFalse(cmd.contains("--settings"))
    }

    func testSettingsFlagAbsentForEmptyCustomFallback() {
        // Empty-custom falls back to plain "command claude" text, but it's
        // still the .custom preset's code path — flags (including
        // --settings) are a .claude-preset-only feature.
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .custom, customCommand: "  ", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none
        )
        XCTAssertFalse(cmd.contains("--settings"))
    }

    // MARK: --session-id (Lot 3, Task 6) — exclusive with --resume/--continue,
    // resume/continue always win. Full id+resumeMode matrix.

    func testSessionIdFlagWhenResumeModeNoneAndIdProvided() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none,
            sessionId: "11111111-1111-1111-1111-111111111111"
        )
        XCTAssertEqual(
            cmd,
            prefix + "command claude --session-id 11111111-1111-1111-1111-111111111111" + settingsFlag
        )
    }

    func testSessionIdOmittedWhenResumeModeIsResumeEvenIfProvided() {
        // resume wins: --resume and --session-id are mutually exclusive, and
        // a caller passing both (shouldn't happen, but the function must
        // still be safe) never emits both flags.
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .resume(sessionId: "abc-123"),
            sessionId: "should-never-appear"
        )
        XCTAssertEqual(cmd, prefix + "command claude --resume abc-123" + settingsFlag)
        XCTAssertFalse(cmd.contains("--session-id"))
    }

    func testSessionIdOmittedWhenResumeModeIsContinueEvenIfProvided() {
        // continue wins, same mutual-exclusivity guarantee as resume above.
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .continueMostRecent,
            sessionId: "should-never-appear"
        )
        XCTAssertEqual(cmd, prefix + "command claude --continue" + settingsFlag)
        XCTAssertFalse(cmd.contains("--session-id"))
    }

    func testNoSessionIdFlagWhenNilAndResumeModeNone() {
        let cmd = OpusPreferences.composeSpawnCommand(
            preset: .claude, customCommand: "", workingDirectory: cwd,
            skipPermissions: false, resumeMode: .none, sessionId: nil
        )
        XCTAssertEqual(cmd, prefix + "command claude" + settingsFlag)
        XCTAssertFalse(cmd.contains("--session-id"))
    }
}
