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

    func testPutRejectsValueContainingNewline() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.put(name: "k", value: "line1\nline2")) { error in
            XCTAssertEqual(
                error as? SecretStoreError,
                .invalidValue("valeur multi-ligne : le Trousseau est mono-ligne ici. Une clé PEM (.p8) reste dans un fichier.")
            )
        }
    }

    func testPutRejectsValueContainingCarriageReturn() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.put(name: "k", value: "line1\rline2")) { error in
            XCTAssertEqual(
                error as? SecretStoreError,
                .invalidValue("valeur multi-ligne : le Trousseau est mono-ligne ici. Une clé PEM (.p8) reste dans un fichier.")
            )
        }
    }

    func testPutRejectsCRLFValue() {
        // Regression guard: Swift treats "\r\n" as a single Character, so a
        // Character-level contains("\n") check silently passes CRLF through.
        // The validator must look at UTF-8 bytes.
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.put(name: "k", value: "line1\r\nline2")) { error in
            guard case .invalidValue = error as? SecretStoreError else {
                return XCTFail("expected .invalidValue, got \(error)")
            }
        }
    }

    /// `find-generic-password -w` prints the value as hex, not as itself,
    /// as soon as it holds one byte outside printable ASCII. Measured
    /// boundary: 0x20 and 0x7E come back as themselves, 0x1F, 0x7F, 0x80
    /// and a UTF-8 e-acute all come back as hex digits. So a value holding
    /// one has to be refused at the door, because the alternative is not
    /// available: hex-decoding on read is ambiguous, and destructively so.
    /// The literal value "610a" and the value "A\tBC" both read back as
    /// plain hex digits, and several real secrets here ARE pure hex.
    func testPutRejectsValueWithBytesOutsidePrintableASCII() {
        let store = InMemorySecretStore()
        for (label, value) in [("e-acute", "clé"), ("tab", "a\tb"), ("del", "a\u{7F}b")] {
            XCTAssertThrowsError(try store.put(name: "k", value: value), label) { error in
                guard case .invalidValue(let reason) = error as? SecretStoreError else {
                    return XCTFail("\(label): expected .invalidValue, got \(error)")
                }
                XCTAssertTrue(reason.contains("ASCII imprimable"), "\(label): \(reason)")
            }
        }
    }

    /// The other half of the boundary: everything from 0x20 to 0x7E goes in,
    /// including the quotes and spaces a passphrase-style credential uses.
    func testPutAcceptsEveryPrintableASCIIByte() throws {
        let store = InMemorySecretStore()
        let printable = String(String.UnicodeScalarView((0x20...0x7E).map { Unicode.Scalar($0)! }))
        try store.put(name: "k", value: printable)
        XCTAssertEqual(try store.value(for: "k"), printable)
    }

    /// A newline is also outside printable ASCII, but it is the case a
    /// person actually hits (pasting a PEM), so it keeps its own message
    /// rather than being folded into the generic one.
    func testMultilineKeepsItsOwnMessageRatherThanTheGenericOne() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.put(name: "k", value: "a\nb")) { error in
            XCTAssertEqual(
                error as? SecretStoreError,
                .invalidValue("valeur multi-ligne : le Trousseau est mono-ligne ici. Une clé PEM (.p8) reste dans un fichier.")
            )
        }
    }

    func testPutRejectsValueOverTheByteCap() {
        let store = InMemorySecretStore()
        let tooLong = String(repeating: "a", count: SecretValueValidator.maximumValueBytes + 1)
        XCTAssertThrowsError(try store.put(name: "k", value: tooLong)) { error in
            XCTAssertEqual(
                error as? SecretStoreError,
                .invalidValue("valeur trop longue (\(SecretValueValidator.maximumValueBytes + 1) octets, maximum \(SecretValueValidator.maximumValueBytes))")
            )
        }
    }

    func testPutAcceptsValueAtExactlyTheByteCap() throws {
        let store = InMemorySecretStore()
        let exact = String(repeating: "a", count: SecretValueValidator.maximumValueBytes)
        try store.put(name: "k", value: exact)
        XCTAssertEqual(try store.value(for: "k"), exact)
    }

    func testValueForInvalidGrammarNameThrowsInvalidNameNotNotFound() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.value(for: "Bad Name")) { error in
            XCTAssertEqual(error as? SecretStoreError, .invalidName("Bad Name"))
        }
    }

    func testRemoveInvalidGrammarNameThrowsInvalidNameNotNotFound() {
        let store = InMemorySecretStore()
        XCTAssertThrowsError(try store.remove(name: "Bad Name")) { error in
            XCTAssertEqual(error as? SecretStoreError, .invalidName("Bad Name"))
        }
    }
}
