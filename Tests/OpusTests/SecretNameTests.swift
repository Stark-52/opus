import XCTest
@testable import OpusSecretsKit

final class SecretNameTests: XCTestCase {
    func testAcceptsGrammarConformingNames() {
        XCTAssertTrue(SecretName.isValid("resend-landing"))
        XCTAssertTrue(SecretName.isValid("asc.key.id"))
        XCTAssertTrue(SecretName.isValid("has_underscore"),
                      "underscore IS in the grammar: slug normalizes it away when deriving a name from an env var, but a hand-typed name may keep it")
        XCTAssertTrue(SecretName.isValid("a"))
        XCTAssertTrue(SecretName.isValid("x9"))
        XCTAssertTrue(SecretName.isValid(String(repeating: "a", count: 64)))
    }

    func testRejectsNonConformingNames() {
        XCTAssertFalse(SecretName.isValid(""), "empty")
        XCTAssertFalse(SecretName.isValid("-leading-dash"), "must start alphanumeric")
        XCTAssertFalse(SecretName.isValid(".leading-dot"), "must start alphanumeric")
        XCTAssertFalse(SecretName.isValid("UPPER"), "lowercase only")
        XCTAssertFalse(SecretName.isValid("has space"))
        XCTAssertFalse(SecretName.isValid("has/slash"))
        XCTAssertFalse(SecretName.isValid("_leading-underscore"), "must start alphanumeric")
        XCTAssertFalse(SecretName.isValid(String(repeating: "a", count: 65)), "65 chars is one too many")
    }

    func testSlugConvertsRealWorldKeys() {
        XCTAssertEqual(SecretName.slug("RESEND_API_KEY"), "resend-api-key")
        XCTAssertEqual(SecretName.slug("Authorization"), "authorization")
        XCTAssertEqual(SecretName.slug("APP_STORE_CONNECT_KEY_ID"), "app-store-connect-key-id")
        XCTAssertEqual(SecretName.slug("my key name"), "my-key-name")
    }

    func testSlugCollapsesRunsToAFixedPoint() {
        // A single replacing pass over "___" yields "--", which still
        // contains the pattern being removed. The implementation must loop
        // to a fixed point, not replace once.
        XCTAssertEqual(SecretName.slug("A___B"), "a-b")
        XCTAssertEqual(SecretName.slug("A_ _ _B"), "a-b")
        XCTAssertEqual(SecretName.slug("A-----B"), "a-b")
    }

    func testSlugTrimsAndTruncatesToValidOutput() {
        XCTAssertEqual(SecretName.slug("__leading"), "leading")
        XCTAssertEqual(SecretName.slug("trailing__"), "trailing")
        XCTAssertEqual(SecretName.slug("trailing."), "trailing")
        XCTAssertEqual(SecretName.slug("!!!"), "")
        XCTAssertEqual(SecretName.slug(String(repeating: "k", count: 100)).count, 64)
    }

    func testSlugHandlesRoughlyTypedPanelNames() {
        // SecretsPanel.commit() runs a hand-typed name through slug() rather
        // than rejecting it outright, so these are exactly the fixtures the
        // panel's friction complaint is about.
        XCTAssertEqual(SecretName.slug("stripe key"), "stripe-key")
        XCTAssertEqual(SecretName.slug("Stripe Key"), "stripe-key")
        XCTAssertEqual(SecretName.slug("resend  key"), "resend-key", "double space collapses like any other run")
        XCTAssertEqual(SecretName.slug("!!!"), "", "nothing usable survives: the panel must reject this, not store an empty name")
    }

    func testSlugOutputIsAlwaysValidOrEmpty() {
        for raw in ["RESEND_API_KEY", "!!!", "___", "9lives", "-x-", String(repeating: "z", count: 200)] {
            let s = SecretName.slug(raw)
            XCTAssertTrue(s.isEmpty || SecretName.isValid(s), "slug(\(raw)) = \(s) is neither empty nor valid")
        }
    }
}
