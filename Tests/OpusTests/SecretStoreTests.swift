import XCTest
@testable import OpusSecretsKit

final class SecretStoreTests: XCTestCase {
    func testInMemoryStoreRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.put(name: "resend-landing", value: "re_live_abc123")
        XCTAssertEqual(try store.value(for: "resend-landing"), "re_live_abc123")
        XCTAssertEqual(try store.names(), ["resend-landing"])
    }

    func testNamesAreSortedForStableDisplay() throws {
        let store = InMemorySecretStore(["zeta": "1", "alpha": "2", "mid": "3"])
        XCTAssertEqual(try store.names(), ["alpha", "mid", "zeta"])
    }

    func testMissingNameThrowsNotFound() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.value(for: "nope")) { error in
            XCTAssertEqual(error as? SecretStoreError, .notFound("nope"))
        }
    }

    func testPutRejectsNamesOutsideTheGrammar() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.put(name: "Bad Name", value: "x")) { error in
            XCTAssertEqual(error as? SecretStoreError, .invalidName("Bad Name"))
        }
    }

    func testPutOverwrites() throws {
        let store = InMemorySecretStore(["k": "old"])
        try store.put(name: "k", value: "new")
        XCTAssertEqual(try store.value(for: "k"), "new")
    }

    func testRemove() throws {
        let store = InMemorySecretStore(["k": "v"])
        try store.remove(name: "k")
        XCTAssertEqual(try store.names(), [])
    }
}
