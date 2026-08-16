import XCTest
@testable import Opus

/// OpusClaudeEvent.parse is the pure core of the hook event bus: it never
/// touches disk or a socket, so every payload shape from the verified hooks
/// contract is exercised directly here as inline JSON fixtures. The
/// (untestable) socket plumbing around it — EventSocketServer — is a thin
/// structural copy of SocketServer and is exercised manually (see task
/// report), not here.
final class EventParsingTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: One realistic fixture per event, per the verified field tables.

    func testUserPromptSubmit() {
        let json = """
        {
          "session_id": "sess-abc123",
          "prompt_id": "550e8400-e29b-41d4-a716-446655440000",
          "transcript_path": "/Users/dev/.claude/projects/-Users-dev-opus/sess-abc123.jsonl",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "permission_mode": "default",
          "hook_event_name": "UserPromptSubmit",
          "prompt": "add the event socket server",
          "user_message_id": "msg_xyz"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        // This fixture was copied from a real payload and has always carried
        // a transcript_path; the parser simply used to throw it away. Now
        // that the field is read, the expectation asserts it, which also
        // makes this fixture the standing proof that the field is real.
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            transcriptPath: "/Users/dev/.claude/projects/-Users-dev-opus/sess-abc123.jsonl",
            kind: .promptSubmitted
        ))
    }

    func testPreToolUse() {
        let json = """
        {
          "session_id": "sess-abc123",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "hook_event_name": "PreToolUse",
          "tool_name": "Bash",
          "tool_input": { "command": "swift test", "description": "Run tests" },
          "tool_use_id": "toolu_01ABC123"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            kind: .toolUse(name: "Bash")
        ))
    }

    func testPostToolUse() {
        let json = """
        {
          "session_id": "sess-abc123",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "hook_event_name": "PostToolUse",
          "tool_name": "Write",
          "tool_input": { "file_path": "/tmp/x.txt" },
          "tool_output": "File written successfully",
          "tool_use_id": "toolu_01ABC123"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            kind: .toolDone
        ))
    }

    func testNotification() {
        let json = """
        {
          "session_id": "sess-abc123",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "hook_event_name": "Notification",
          "type": "permission_prompt",
          "message": "Permission required for Bash"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            kind: .needsAttention(kind: "permission_prompt", message: "Permission required for Bash")
        ))
    }

    func testStop() {
        let json = """
        {
          "session_id": "sess-abc123",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "hook_event_name": "Stop",
          "last_assistant_message": "Here's the result...",
          "stop_reason": "end_turn"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            kind: .turnEnded
        ))
    }

    func testSessionStart() {
        let json = """
        {
          "session_id": "sess-abc123",
          "cwd": "/Users/dev/Documents/GitHub/opus",
          "hook_event_name": "SessionStart",
          "source": "startup",
          "model": "claude-sonnet-5"
        }
        """
        let event = OpusClaudeEvent.parse(line: data(json))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-abc123",
            cwd: "/Users/dev/Documents/GitHub/opus",
            kind: .sessionStarted(source: "startup")
        ))
    }

    // MARK: Malformed / unexpected input never crashes, always nil.

    func testInvalidJSONIsNil() {
        XCTAssertNil(OpusClaudeEvent.parse(line: data("not json at all {{{")))
    }

    func testEmptyLineIsNil() {
        XCTAssertNil(OpusClaudeEvent.parse(line: data("")))
    }

    func testMissingHookEventNameIsNil() {
        let json = """
        { "session_id": "sess-abc123", "cwd": "/Users/dev/opus" }
        """
        XCTAssertNil(OpusClaudeEvent.parse(line: data(json)))
    }

    func testUnrecognizedHookEventNameIsNil() {
        // A future/unregistered event (we only register six) must not crash
        // the parser or produce a bogus Kind.
        let json = """
        { "session_id": "sess-abc123", "cwd": "/Users/dev/opus", "hook_event_name": "PermissionRequest" }
        """
        XCTAssertNil(OpusClaudeEvent.parse(line: data(json)))
    }

    func testJSONArrayInsteadOfObjectIsNil() {
        XCTAssertNil(OpusClaudeEvent.parse(line: data("[1,2,3]")))
    }

    // MARK: Raw-newline gaps pre-compacted (opus-attach's line-framing safety).

    /// opus-attach replaces every raw 0x0A/0x0D byte in the hook's stdin with
    /// a space before writing to the socket (claude's hook stdin can be
    /// pretty-printed). This fixture starts as genuinely pretty-printed JSON
    /// with real newlines, then applies the SAME compaction opus-attach
    /// performs, proving parse() copes with the resulting run of spaces
    /// exactly like it would receive over the wire.
    func testPreCompactedPrettyPrintedPayloadStillParses() {
        let pretty = """
        {
          "session_id": "sess-777",
          "cwd": "/Users/dev/project",
          "hook_event_name": "PreToolUse",
          "tool_name": "Write",
          "tool_input": {
            "file_path": "/tmp/x.txt"
          }
        }
        """
        let compacted = pretty
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let event = OpusClaudeEvent.parse(line: data(compacted))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-777",
            cwd: "/Users/dev/project",
            kind: .toolUse(name: "Write")
        ))
    }

    /// Same idea but with CRLF line endings (Windows-authored transcripts,
    /// or a hook payload that round-tripped through something that
    /// normalizes to \r\n) — both 0x0A and 0x0D must be blanked.
    func testCRLFCompactedPayloadStillParses() {
        let prettyCRLF = "{\r\n  \"session_id\": \"sess-crlf\",\r\n  \"cwd\": \"/Users/dev/opus\",\r\n  \"hook_event_name\": \"SessionStart\",\r\n  \"source\": \"resume\"\r\n}"
        let compacted = prettyCRLF
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let event = OpusClaudeEvent.parse(line: data(compacted))
        XCTAssertEqual(event, OpusClaudeEvent(
            sessionId: "sess-crlf",
            cwd: "/Users/dev/opus",
            kind: .sessionStarted(source: "resume")
        ))
    }

    // MARK: Pane attribution fields (added when /resume was found to leave a
    // pane bound to a session id whose transcript never exists)

    func testTranscriptPathIsParsedWhenPresent() {
        let line = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/c","transcript_path":"/t/s.jsonl"}"#.utf8)
        XCTAssertEqual(OpusClaudeEvent.parse(line: line)?.transcriptPath, "/t/s.jsonl")
    }

    func testRelayPidIsParsedWhenPresent() {
        let line = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/c","opus_pid":4242}"#.utf8)
        XCTAssertEqual(OpusClaudeEvent.parse(line: line)?.relayPid, 4242)
    }

    func testBothFieldsAbsentIsNotAnError() {
        // An opus-attach from before this change is still a valid relay: the
        // event must parse, just without attribution.
        let line = Data(#"{"hook_event_name":"Stop","session_id":"s","cwd":"/c"}"#.utf8)
        let event = OpusClaudeEvent.parse(line: line)
        XCTAssertEqual(event?.transcriptPath, "")
        XCTAssertEqual(event?.relayPid, 0)
    }
}
