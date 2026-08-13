import XCTest
@testable import OpusSecretsKit

/// A store whose every read fails with a chosen error. `InMemorySecretStore`
/// can only produce `.notFound`, so it cannot express "the Keychain is
/// locked", which is exactly the case `runPre` must report differently.
private final class FailingSecretStore: SecretStore {
    private let error: SecretStoreError
    init(error: SecretStoreError) { self.error = error }
    func names() throws -> [String] { throw error }
    func value(for name: String) throws -> String { throw error }
    func put(name: String, value: String) throws { throw error }
    func remove(name: String) throws { throw error }
}

final class HookRunnerTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opus-secrets-hook-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func runner(_ seed: [String: String] = [:]) -> HookRunner {
        HookRunner(store: InMemorySecretStore(seed), usage: SessionUsage(directory: dir))
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func preInput(command: String, sessionID: String = "s1") -> Data {
        json([
            "session_id": sessionID,
            "hook_event_name": "PreToolUse",
            "tool_name": "Bash",
            "tool_input": ["command": command, "description": "does a thing"]
        ])
    }

    func testNoPlaceholderProducesNoOutput() {
        XCTAssertNil(runner().runPre(input: preInput(command: "ls -la")))
    }

    func testSubstitutesOnlyTheCommandField() throws {
        let out = try XCTUnwrap(runner(["k": "VALUE"]).runPre(input: preInput(command: "echo {{secret:k}}")))
        let root = try decode(out)
        XCTAssertEqual(root["suppressOutput"] as? Bool, true,
                       "without this, Claude Code writes this stdout (the substituted secret) into the transcript")
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "echo VALUE")
        XCTAssertEqual(updated["description"] as? String, "does a thing",
                       "non-command fields must survive verbatim: updatedInput replaces the whole object")
    }

    func testUnknownNameDeniesAndNeverSubstitutes() throws {
        let out = try XCTUnwrap(runner(["known": "V"]).runPre(input: preInput(command: "echo {{secret:typo}}")))
        let root = try decode(out)
        XCTAssertEqual(root["suppressOutput"] as? Bool, true, "a refusal must be suppressed too, like every other response")
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertNil(specific["updatedInput"])
        let reason = try XCTUnwrap(specific["permissionDecisionReason"] as? String)
        XCTAssertTrue(reason.contains("typo"))
        XCTAssertTrue(reason.contains("known"), "the reason must list what IS available so the error self-repairs")
    }

    func testOneMissingNameAmongSeveralDeniesTheWholeCommand() throws {
        let runner = self.runner(["a": "A", "b": "B"])
        let input = preInput(command: "{{secret:a}} {{secret:b}} {{secret:c}}")
        let specific = try XCTUnwrap(try decode(try XCTUnwrap(runner.runPre(input: input)))["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
    }

    func testSuccessfulSubstitutionRecordsUsage() throws {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(["k": "VALUE"]), usage: usage)
        _ = runner.runPre(input: preInput(command: "echo {{secret:k}}", sessionID: "sess-42"))
        XCTAssertEqual(usage.names(sessionID: "sess-42"), ["k"])
    }

    func testDeniedCommandRecordsNothing() {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(), usage: usage)
        _ = runner.runPre(input: preInput(command: "echo {{secret:nope}}", sessionID: "sess-42"))
        XCTAssertFalse(usage.hasAny(sessionID: "sess-42"))
    }

    func testKeychainFailureIsReportedAsSuchNotAsAMissingSecret() throws {
        // A locked Keychain must not be reported as "secret introuvable":
        // the store distinguishes .commandFailed from .notFound precisely so
        // this message can be truthful, and `try?` would throw that away.
        let store = FailingSecretStore(error: .commandFailed("keychain is locked"))
        let runner = HookRunner(store: store, usage: SessionUsage(directory: dir))
        let out = try XCTUnwrap(runner.runPre(input: preInput(command: "echo {{secret:k}}")))
        let specific = try XCTUnwrap(try decode(out)["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        let reason = try XCTUnwrap(specific["permissionDecisionReason"] as? String)
        XCTAssertTrue(reason.contains("Trousseau inaccessible"), "got: \(reason)")
        XCTAssertFalse(reason.contains("introuvable."), "must not blame a missing secret")
    }

    func testMalformedInputProducesNoOutput() {
        XCTAssertNil(runner().runPre(input: Data("{{secret:k}} not json".utf8)))
    }

    func testNonBashToolIsLeftAlone() {
        let input = json([
            "session_id": "s1",
            "tool_name": "Write",
            "tool_input": ["content": "{{secret:k}}"]
        ])
        XCTAssertNil(runner(["k": "V"]).runPre(input: input),
                     "substitution is Bash-only by design (spec section 5.4)")
    }

    // MARK: PostToolUse

    private func postInput(response: Any, sessionID: String = "s1") -> Data {
        json([
            "session_id": sessionID,
            "hook_event_name": "PostToolUse",
            "tool_name": "Bash",
            "tool_response": response
        ])
    }

    func testPostWithNoRecordedUsageProducesNoOutput() {
        let input = postInput(response: ["stdout": "re_live_abc123", "stderr": ""])
        XCTAssertNil(runner(["k": "re_live_abc123"]).runPost(input: input),
                     "no session file means nothing was ever substituted, so there is nothing to redact")
    }

    func testPostRedactsAUsedSecretAndPreservesShape() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["resend"], sessionID: "s1")
        let runner = HookRunner(store: InMemorySecretStore(["resend": "re_live_abc123"]), usage: usage)

        let input = postInput(response: ["stdout": "KEY=re_live_abc123\n", "stderr": "", "interrupted": false])
        let out = try XCTUnwrap(runner.runPost(input: input))
        let root = try decode(out)
        XCTAssertEqual(root["suppressOutput"] as? Bool, true)
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PostToolUse")

        let updated = try XCTUnwrap(specific["updatedToolOutput"] as? [String: Any])
        XCTAssertEqual(updated["stdout"] as? String, "KEY=[secret:resend]\n")
        XCTAssertEqual(updated["stderr"] as? String, "")
        XCTAssertEqual(updated["interrupted"] as? Bool, false,
                       "non-string keys must survive so the result still matches the tool's output shape")
    }

    func testPostProducesNoOutputWhenNothingActuallyChanged() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["resend"], sessionID: "s1")
        let runner = HookRunner(store: InMemorySecretStore(["resend": "re_live_abc123"]), usage: usage)
        XCTAssertNil(runner.runPost(input: postInput(response: ["stdout": "all good", "stderr": ""])))
    }

    func testPostIgnoresSecretsNotUsedInThisSession() {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["used"], sessionID: "s1")
        let runner = HookRunner(
            store: InMemorySecretStore(["used": "aaaaaaaaaa", "unused": "bbbbbbbbbb"]),
            usage: usage
        )
        XCTAssertNil(runner.runPost(input: postInput(response: ["stdout": "bbbbbbbbbb"])),
                     "an unused secret cannot have leaked, so it is not in the redaction set")
    }

    func testPostRedactsInsideAStringResponse() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["k"], sessionID: "s1")
        let runner = HookRunner(store: InMemorySecretStore(["k": "aaaaaaaaaa"]), usage: usage)

        let out = try XCTUnwrap(runner.runPost(input: postInput(response: "value is aaaaaaaaaa")))
        let specific = try XCTUnwrap(try decode(out)["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["updatedToolOutput"] as? String, "value is [secret:k]")
    }

    func testPostPreservesATopLevelArrayResponse() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["k"], sessionID: "s1")
        let runner = HookRunner(store: InMemorySecretStore(["k": "aaaaaaaaaa"]), usage: usage)

        let out = try XCTUnwrap(runner.runPost(input: postInput(response: ["aaaaaaaaaa", 42, true])))
        let specific = try XCTUnwrap(try decode(out)["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedToolOutput"] as? [Any])
        XCTAssertEqual(updated[0] as? String, "[secret:k]")
        XCTAssertEqual(updated[1] as? Int, 42)
        XCTAssertEqual(updated[2] as? Bool, true)
    }

    func testPostPreservesNestedDictionaries() throws {
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["k"], sessionID: "s1")
        let runner = HookRunner(store: InMemorySecretStore(["k": "aaaaaaaaaa"]), usage: usage)

        let response: [String: Any] = ["outer": ["inner": ["leaf": "x aaaaaaaaaa y", "n": 7]]]
        let out = try XCTUnwrap(runner.runPost(input: postInput(response: response)))
        let specific = try XCTUnwrap(try decode(out)["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedToolOutput"] as? [String: Any])
        let outer = try XCTUnwrap(updated["outer"] as? [String: Any])
        let inner = try XCTUnwrap(outer["inner"] as? [String: Any])
        XCTAssertEqual(inner["leaf"] as? String, "x [secret:k] y")
        XCTAssertEqual(inner["n"] as? Int, 7)
    }

    func testPostWarnsAndProducesNoOutputWhenTheKeychainCannotBeRead() {
        // The redaction net silently ceasing to work is the worst outcome for
        // this function: output flows to the model unredacted and nothing says
        // so. A locked Keychain mid-session (screen sleep) is the realistic
        // trigger. With no readable value the redactor is empty, so runPost
        // must return nil rather than emit an identity payload — and the
        // stderr warning is what makes the failure visible at all.
        let usage = SessionUsage(directory: dir)
        usage.record(names: ["resend"], sessionID: "s1")
        let runner = HookRunner(store: FailingSecretStore(error: .commandFailed("keychain is locked")),
                                usage: usage)
        XCTAssertNil(runner.runPost(input: postInput(response: ["stdout": "re_live_abc123"])))
    }

    // MARK: SessionStart

    func testSessionStartListsNamesOnly() throws {
        let runner = self.runner(["resend-landing": "V1", "asc-key-id": "V2"])
        let out = try XCTUnwrap(runner.runSessionStart(input: json(["hook_event_name": "SessionStart"])))
        let root = try decode(out)
        XCTAssertEqual(root["suppressOutput"] as? Bool, true)
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "SessionStart")

        let context = try XCTUnwrap(specific["additionalContext"] as? String)
        XCTAssertTrue(context.contains("asc-key-id"))
        XCTAssertTrue(context.contains("resend-landing"))
        XCTAssertTrue(context.contains("{{secret:"), "Claude must be told the calling convention")
        XCTAssertFalse(context.contains("V1"), "values must never appear")
        XCTAssertFalse(context.contains("V2"))
    }

    func testSessionStartWithAnEmptyStoreProducesNoOutput() {
        XCTAssertNil(runner().runSessionStart(input: json(["hook_event_name": "SessionStart"])))
    }
}
