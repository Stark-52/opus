import XCTest
@testable import OpusSecretsKit

/// A store whose `remove` always fails, used to exercise the
/// newWrittenOldRemains path: InMemorySecretStore's own remove only fails
/// on a missing name, which rename() already screens out before it ever
/// gets there, so that branch needs a store that can fail after `put` has
/// already succeeded.
private final class RemoveFailingStore: SecretStore {
    private let backing: InMemorySecretStore

    init(_ seed: [String: String]) { backing = InMemorySecretStore(seed) }

    func names() throws -> [String] { try backing.names() }
    func value(for name: String) throws -> String { try backing.value(for: name) }
    func put(name: String, value: String) throws { try backing.put(name: name, value: value) }
    func remove(name: String) throws { throw SecretStoreError.commandFailed("simulated remove failure") }
}

final class SecretRenamerTests: XCTestCase {
    func testHappyPathMovesTheValueAndRemovesTheOld() {
        let store = InMemorySecretStore(["stripe-key": "sk_live_123"])
        let outcome = SecretRenamer.rename(store, from: "stripe-key", toRaw: "stripe-live")
        XCTAssertEqual(outcome, .renamed(newName: "stripe-live"))
        XCTAssertEqual(try? store.value(for: "stripe-live"), "sk_live_123")
        XCTAssertThrowsError(try store.value(for: "stripe-key")) { error in
            XCTAssertEqual(error as? SecretStoreError, .notFound("stripe-key"))
        }
    }

    func testUnknownOldNameRefuses() {
        let store = InMemorySecretStore(["resend-landing": "re_123"])
        let outcome = SecretRenamer.rename(store, from: "nope", toRaw: "new-name")
        XCTAssertEqual(outcome, .oldNameNotFound(available: ["resend-landing"]))
        // Nothing moved.
        XCTAssertEqual(try? store.names(), ["resend-landing"])
    }

    func testExistingNewNameRefusesWithoutClobbering() {
        let store = InMemorySecretStore(["stripe-key": "sk_live_123", "stripe-live": "sk_live_OLD"])
        let outcome = SecretRenamer.rename(store, from: "stripe-key", toRaw: "stripe-live")
        XCTAssertEqual(outcome, .newNameAlreadyExists(newName: "stripe-live"))
        // Neither entry was touched.
        XCTAssertEqual(try? store.value(for: "stripe-key"), "sk_live_123")
        XCTAssertEqual(try? store.value(for: "stripe-live"), "sk_live_OLD")
    }

    func testNewNameIsSlugged() {
        let store = InMemorySecretStore(["stripe-key": "sk_live_123"])
        let outcome = SecretRenamer.rename(store, from: "stripe-key", toRaw: "stripe live")
        XCTAssertEqual(outcome, .renamed(newName: "stripe-live"))
        XCTAssertEqual(try? store.value(for: "stripe-live"), "sk_live_123")
    }

    func testNewNameThatSlugsToEmptyIsRefused() {
        let store = InMemorySecretStore(["stripe-key": "sk_live_123"])
        let outcome = SecretRenamer.rename(store, from: "stripe-key", toRaw: "!!!")
        XCTAssertEqual(outcome, .invalidNewName(raw: "!!!"))
        XCTAssertEqual(try? store.value(for: "stripe-key"), "sk_live_123")
    }

    func testStoreErrorOnNamesIsPropagatedNotFlattened() {
        // A names() failure must not be reported as "old name not found":
        // the old name might well exist, the Keychain is just unreadable.
        final class BrokenNamesStore: SecretStore {
            func names() throws -> [String] { throw SecretStoreError.commandFailed("Trousseau verrouillé") }
            func value(for name: String) throws -> String { throw SecretStoreError.notFound(name) }
            func put(name: String, value: String) throws {}
            func remove(name: String) throws {}
        }
        let outcome = SecretRenamer.rename(BrokenNamesStore(), from: "stripe-key", toRaw: "stripe-live")
        XCTAssertEqual(outcome, .storeError("\(SecretStoreError.commandFailed("Trousseau verrouillé"))"))
    }

    func testOldRemovalFailureAfterSuccessfulWriteReportsBothNamesExplicitly() {
        let store = RemoveFailingStore(["stripe-key": "sk_live_123"])
        let outcome = SecretRenamer.rename(store, from: "stripe-key", toRaw: "stripe-live")
        XCTAssertEqual(
            outcome,
            .newWrittenOldRemains(
                newName: "stripe-live",
                oldName: "stripe-key",
                removeError: "\(SecretStoreError.commandFailed("simulated remove failure"))"
            )
        )
        // The new entry was in fact written: the value now lives under BOTH
        // names, which is exactly what the caller must be told.
        XCTAssertEqual(try? store.value(for: "stripe-live"), "sk_live_123")
    }
}
