import XCTest
@testable import OpusSecretsKit

/// Fails every `put` AFTER the first one, so the "rename landed, value
/// write behind it did not" path can be reached: the rename's own put must
/// succeed for that state to exist at all.
private final class SecondPutFailingStore: SecretStore {
    private let backing: InMemorySecretStore
    private var puts = 0

    init(_ seed: [String: String]) { backing = InMemorySecretStore(seed) }

    func names() throws -> [String] { try backing.names() }
    func value(for name: String) throws -> String { try backing.value(for: name) }
    func remove(name: String) throws { try backing.remove(name: name) }
    func put(name: String, value: String) throws {
        puts += 1
        guard puts > 1 else { return try backing.put(name: name, value: value) }
        throw SecretStoreError.commandFailed("simulated put failure")
    }
}

private final class NamesFailingStore: SecretStore {
    func names() throws -> [String] { throw SecretStoreError.commandFailed("keychain locked") }
    func value(for name: String) throws -> String { throw SecretStoreError.notFound(name) }
    func put(name: String, value: String) throws {}
    func remove(name: String) throws {}
}

final class SecretEditorTests: XCTestCase {

    // MARK: The three things the pencil button is for

    func testRenameOnlyKeepsTheValue() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        let outcome = SecretEditor.edit(store, original: "aws-key-id",
                                        rawNewName: "aws-access-key-id", newValue: "")
        XCTAssertEqual(outcome, .renamed(newName: "aws-access-key-id"))
        XCTAssertEqual(try? store.value(for: "aws-access-key-id"), "AKIA_OLD")
        XCTAssertFalse((try? store.names())?.contains("aws-key-id") ?? true)
    }

    func testValueOnlyKeepsTheName() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        let outcome = SecretEditor.edit(store, original: "aws-key-id",
                                        rawNewName: "aws-key-id", newValue: "AKIA_NEW")
        XCTAssertEqual(outcome, .valueReplaced(name: "aws-key-id"))
        XCTAssertEqual(try? store.value(for: "aws-key-id"), "AKIA_NEW")
    }

    func testBothAtOnceLandsUnderTheNewNameWithTheNewValue() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        let outcome = SecretEditor.edit(store, original: "aws-key-id",
                                        rawNewName: "aws-access-key-id", newValue: "AKIA_NEW")
        XCTAssertEqual(outcome, .renamedAndValueReplaced(newName: "aws-access-key-id"))
        XCTAssertEqual(try? store.value(for: "aws-access-key-id"), "AKIA_NEW")
        XCTAssertFalse((try? store.names())?.contains("aws-key-id") ?? true)
    }

    // MARK: Nothing asked, nothing done

    func testSameNameAndEmptyValueChangesNothing() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        XCTAssertEqual(SecretEditor.edit(store, original: "aws-key-id",
                                         rawNewName: "aws-key-id", newValue: ""), .unchanged)
        XCTAssertEqual(try? store.value(for: "aws-key-id"), "AKIA_OLD")
    }

    /// The name field is hand-typed, so it goes through the same slug the
    /// deposit field does: retyping the name with a space is still "the
    /// same name", not a rename to a new one.
    func testATypedNameIsSluggedBeforeItCountsAsARename() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        XCTAssertEqual(SecretEditor.edit(store, original: "aws-key-id",
                                         rawNewName: "AWS Key Id", newValue: ""), .unchanged)
    }

    // MARK: Refusals

    func testUnusableNewNameIsRefusedAndNothingMoves() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD"])
        XCTAssertEqual(SecretEditor.edit(store, original: "aws-key-id",
                                         rawNewName: "!!!", newValue: "AKIA_NEW"),
                       .invalidNewName(raw: "!!!"))
        XCTAssertEqual(try? store.value(for: "aws-key-id"), "AKIA_OLD")
    }

    func testRenamingOntoAnExistingNameIsRefused() {
        let store = InMemorySecretStore(["aws-key-id": "AKIA_OLD", "aws-secret": "s3cr3t"])
        XCTAssertEqual(SecretEditor.edit(store, original: "aws-key-id",
                                         rawNewName: "aws-secret", newValue: ""),
                       .newNameAlreadyExists(newName: "aws-secret"))
        XCTAssertEqual(try? store.value(for: "aws-secret"), "s3cr3t")
        XCTAssertEqual(try? store.value(for: "aws-key-id"), "AKIA_OLD")
    }

    func testEditingSomethingThatIsNoLongerThereIsNotASilentCreate() {
        let store = InMemorySecretStore([:])
        XCTAssertEqual(SecretEditor.edit(store, original: "aws-key-id",
                                         rawNewName: "aws-key-id", newValue: "AKIA_NEW"),
                       .notFound(available: []))
        XCTAssertFalse((try? store.names())?.contains("aws-key-id") ?? true)
    }

    /// Fail closed: an unreadable name list must never fall through to a
    /// `put` that would replace in place with no warning.
    func testAnUnreadableStoreRefusesRatherThanWritingBlind() {
        let outcome = SecretEditor.edit(NamesFailingStore(), original: "aws-key-id",
                                        rawNewName: "aws-key-id", newValue: "AKIA_NEW")
        guard case .storeError = outcome else {
            return XCTFail("attendu .storeError, obtenu \(outcome)")
        }
    }

    // MARK: The partial failure nobody reproduces by clicking

    func testRenameThatLandsWithAFailedValueWriteIsReportedUnderTheNewName() {
        let store = SecondPutFailingStore(["aws-key-id": "AKIA_OLD"])
        let outcome = SecretEditor.edit(store, original: "aws-key-id",
                                        rawNewName: "aws-access-key-id", newValue: "AKIA_NEW")
        guard case .renamedButValueFailed(let newName, _) = outcome else {
            return XCTFail("attendu .renamedButValueFailed, obtenu \(outcome)")
        }
        // The caller must point the user at the NEW name: that is where the
        // secret now lives, still carrying its old value.
        XCTAssertEqual(newName, "aws-access-key-id")
        XCTAssertEqual(try? store.value(for: "aws-access-key-id"), "AKIA_OLD")
    }
}
