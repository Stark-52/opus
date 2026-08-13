import XCTest
@testable import OpusSecretsKit

/// A store whose every read fails with a chosen error. `InMemorySecretStore`
/// always returns successfully from `names()` — an empty or populated list,
/// never a throw — so it cannot express "the Keychain is locked", which is
/// exactly the case `runPre` must report differently from "name not found".
private final class FailingSecretStore: SecretStore {
    private let error: SecretStoreError
    init(error: SecretStoreError) { self.error = error }
    func names() throws -> [String] { throw error }
    func value(for name: String) throws -> String { throw error }
    func put(name: String, value: String) throws { throw error }
    func remove(name: String) throws { throw error }
}

/// Fixed rather than `CommandLine.arguments[0]`, so an assertion on the
/// rewritten command text is checking a known string, not a machine- and
/// build-directory-dependent one.
private let testBinaryPath = "/usr/local/bin/opus-secrets"

/// `'\(testBinaryPath)'` — the exact form CommandSubstitutionRewriter emits
/// via its own copy of the repo's shellQuote idiom.
private let quotedTestBinaryPath = "'\(testBinaryPath)'"

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

    private func runner(_ seed: [String: String] = [:], binaryPath: String = testBinaryPath) -> HookRunner {
        HookRunner(store: InMemorySecretStore(seed), usage: SessionUsage(directory: dir), binaryPath: binaryPath)
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

    /// Runs `runPre` and returns the rewritten `command` from a successful
    /// response, failing the test if the response was a refusal or malformed.
    private func rewrittenCommand(_ runner: HookRunner, command: String, sessionID: String = "s1") throws -> String {
        let out = try XCTUnwrap(runner.runPre(input: preInput(command: command, sessionID: sessionID)))
        let root = try decode(out)
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertNil(specific["permissionDecision"], "expected success, got a refusal")
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        return try XCTUnwrap(updated["command"] as? String)
    }

    func testNoPlaceholderProducesNoOutput() {
        XCTAssertNil(runner().runPre(input: preInput(command: "ls -la")))
    }

    // MARK: Command substitution rewrite — quote contexts

    func testPlaceholderOutsideAnyQuotesBecomesAQuotedCommandSubstitution() throws {
        let out = try XCTUnwrap(runner(["k": "VALUE"]).runPre(input: preInput(command: "echo {{secret:k}}")))
        let root = try decode(out)
        XCTAssertEqual(root["suppressOutput"] as? Bool, true,
                       "without this, Claude Code writes this stdout into the transcript")
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "echo \"$(\(quotedTestBinaryPath) get k)\"",
                       "outside any quotes, the splice must add its OWN double quotes: unquoted $(...) word-splits")
        XCTAssertEqual(updated["description"] as? String, "does a thing",
                       "non-command fields must survive verbatim: updatedInput replaces the whole object")
    }

    func testPlaceholderInsideDoubleQuotesBecomesABareCommandSubstitution() throws {
        let runner = self.runner(["k": "VALUE"])
        let command = try rewrittenCommand(runner, command: "curl -H \"Auth: Bearer {{secret:k}}\"")
        XCTAssertEqual(command, "curl -H \"Auth: Bearer $(\(quotedTestBinaryPath) get k)\"",
                       "already inside double quotes, so no extra pair is added — that would nest incorrectly")
    }

    func testPlaceholderInsideSingleQuotesIsRefused() throws {
        let out = try XCTUnwrap(runner(["k": "VALUE"]).runPre(input: preInput(command: "curl -H 'Auth: Bearer {{secret:k}}'")))
        let root = try decode(out)
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertNil(specific["updatedInput"])
        let reason = try XCTUnwrap(specific["permissionDecisionReason"] as? String)
        XCTAssertTrue(reason.contains("k"), "the reason must name the offending secret; got: \(reason)")
        XCTAssertTrue(reason.contains("guillemets simples"), "must explain WHY: $(...) does not expand in '...'; got: \(reason)")
    }

    func testPlaceholderImmediatelyPrecededByABackslashIsRefusedWithADistinctMessage() throws {
        // printf %s \{{secret:k}} — zero gap. See CommandSubstitutionRewriterTests
        // for real-shell proof of why this cannot be rewritten safely in
        // either quote context; here we only need HookRunner to surface a
        // refusal, and a DIFFERENT reason than the single-quote one.
        let out = try XCTUnwrap(runner(["k": "VALUE"]).runPre(input: preInput(command: "printf %s \\{{secret:k}}")))
        let root = try decode(out)
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["permissionDecision"] as? String, "deny")
        XCTAssertNil(specific["updatedInput"])
        let reason = try XCTUnwrap(specific["permissionDecisionReason"] as? String)
        XCTAssertTrue(reason.contains("k"), "the reason must name the offending secret; got: \(reason)")
        XCTAssertTrue(reason.contains("antislash"), "must explain WHY: a live backslash precedes it; got: \(reason)")
        XCTAssertFalse(reason.contains("guillemets simples"),
                       "this is a different failure than the single-quote one and must not reuse its wording")
    }

    func testTwoPlaceholdersInDifferentQuoteContextsAreEachHandledCorrectly() throws {
        let runner = self.runner(["a": "A", "b": "B"])
        let command = try rewrittenCommand(
            runner, command: "echo {{secret:a}} && curl -H \"X: {{secret:b}}\""
        )
        XCTAssertEqual(
            command,
            "echo \"$(\(quotedTestBinaryPath) get a)\" && curl -H \"X: $(\(quotedTestBinaryPath) get b)\""
        )
    }

    func testEscapedDoubleQuoteOutsideQuotesDoesNotOpenARegion() throws {
        // Shell text: echo \" {{secret:k}}  — an escaped, literal quote
        // outside any quoted region. It must not be mistaken for an opener,
        // which would leave the scanner thinking the placeholder sits
        // inside double quotes and wrongly emit a bare (unquoted)
        // substitution.
        let runner = self.runner(["k": "V"])
        let command = try rewrittenCommand(runner, command: "echo \\\" {{secret:k}}")
        XCTAssertEqual(command, "echo \\\" \"$(\(quotedTestBinaryPath) get k)\"")
    }

    func testSingleQuoteInsideADoubleQuotedRegionDoesNotCloseIt() throws {
        // Shell text: curl -H "It's {{secret:k}}"  — the apostrophe has no
        // special meaning inside double quotes. If the scanner mistook it
        // for a quote character, it would think it left the double-quoted
        // region and (depending on what followed) either wrap with an extra
        // pair of quotes or refuse the command outright.
        let runner = self.runner(["k": "V"])
        let command = try rewrittenCommand(runner, command: "curl -H \"It's {{secret:k}}\"")
        XCTAssertEqual(command, "curl -H \"It's $(\(quotedTestBinaryPath) get k)\"")
    }

    func testBackslashInsideSingleQuotesDoesNotEscapeTheClosingQuote() throws {
        // Shell text: echo '\' {{secret:k}}  — POSIX single quotes give NO
        // special meaning to backslash, so '\' is a COMPLETE, already-closed
        // three-character single-quoted region containing one backslash.
        // The placeholder that follows sits outside any quotes. A scanner
        // that wrongly let backslash escape here would treat the region as
        // never closing, and the placeholder would be refused as if it were
        // single-quoted — which it is not.
        let runner = self.runner(["k": "V"])
        let command = try rewrittenCommand(runner, command: "echo '\\' {{secret:k}}")
        XCTAssertEqual(command, "echo '\\' \"$(\(quotedTestBinaryPath) get k)\"")
    }

    func testEmittedCommandContainsTheSecretNameAndNeverAValue() throws {
        let runner = self.runner(["k": "SUPER-SECRET-DO-NOT-LEAK"])
        let out = try XCTUnwrap(runner.runPre(input: preInput(command: "echo {{secret:k}}")))
        let raw = try XCTUnwrap(String(data: out, encoding: .utf8))
        XCTAssertFalse(raw.contains("SUPER-SECRET-DO-NOT-LEAK"),
                       "the hook's own stdout is what Claude Code writes to the transcript, so it must never carry a value")
        let command = try rewrittenCommand(runner, command: "echo {{secret:k}}")
        XCTAssertTrue(command.contains("get k)"), "must reference the secret by NAME")
    }

    // MARK: Existence checks (unchanged behaviour, now backed by store.names())

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

    func testKeychainFailureIsReportedAsSuchNotAsAMissingSecret() throws {
        // A locked Keychain must not be reported as "secret introuvable":
        // the store distinguishes a store-wide throw from a name simply
        // being absent from a successful `names()` listing, precisely so
        // this message can be truthful.
        let store = FailingSecretStore(error: .commandFailed("keychain is locked"))
        let runner = HookRunner(store: store, usage: SessionUsage(directory: dir), binaryPath: testBinaryPath)
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

    // MARK: Usage recording

    func testSuccessfulRewriteRecordsUsage() throws {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(["k": "VALUE"]), usage: usage, binaryPath: testBinaryPath)
        _ = runner.runPre(input: preInput(command: "echo {{secret:k}}", sessionID: "sess-42"))
        XCTAssertEqual(usage.names(sessionID: "sess-42"), ["k"])
    }

    func testDeniedCommandRecordsNothing() {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(), usage: usage, binaryPath: testBinaryPath)
        _ = runner.runPre(input: preInput(command: "echo {{secret:nope}}", sessionID: "sess-42"))
        XCTAssertFalse(usage.hasAny(sessionID: "sess-42"))
    }

    func testRefusalForSingleQuotesRecordsNothing() {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(["k": "V"]), usage: usage, binaryPath: testBinaryPath)
        _ = runner.runPre(input: preInput(command: "echo '{{secret:k}}'", sessionID: "sess-77"))
        XCTAssertFalse(usage.hasAny(sessionID: "sess-77"),
                       "the command never runs (it is refused), so recording it as used would be a lie")
    }

    func testRefusalForAPendingEscapeRecordsNothing() {
        let usage = SessionUsage(directory: dir)
        let runner = HookRunner(store: InMemorySecretStore(["k": "V"]), usage: usage, binaryPath: testBinaryPath)
        _ = runner.runPre(input: preInput(command: "printf %s \\{{secret:k}}", sessionID: "sess-88"))
        XCTAssertFalse(usage.hasAny(sessionID: "sess-88"),
                       "the command never runs (it is refused), so recording it as used would be a lie")
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
