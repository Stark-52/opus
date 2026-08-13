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
        let specific = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(specific["hookEventName"] as? String, "PreToolUse")
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "echo VALUE")
        XCTAssertEqual(updated["description"] as? String, "does a thing",
                       "non-command fields must survive verbatim: updatedInput replaces the whole object")
    }

    func testUnknownNameDeniesAndNeverSubstitutes() throws {
        let out = try XCTUnwrap(runner(["known": "V"]).runPre(input: preInput(command: "echo {{secret:typo}}")))
        let specific = try XCTUnwrap(try decode(out)["hookSpecificOutput"] as? [String: Any])
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
}
