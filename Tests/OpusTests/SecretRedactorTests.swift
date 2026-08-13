import XCTest
@testable import OpusSecretsKit

final class SecretRedactorTests: XCTestCase {
    func testReplacesKnownValueAnywhereInTheLine() {
        let r = SecretRedactor(secrets: [(name: "resend", value: "re_live_abc123")])
        XCTAssertEqual(r.redactKnownValues("RESEND_API_KEY=re_live_abc123 done"),
                       "RESEND_API_KEY=[secret:resend] done")
    }

    func testReplacesEveryOccurrence() {
        let r = SecretRedactor(secrets: [(name: "k", value: "abcdefgh")])
        XCTAssertEqual(r.redactKnownValues("abcdefgh abcdefgh"), "[secret:k] [secret:k]")
    }

    func testLongestValueWinsWhenOneContainsTheOther() {
        // Redacting "abcdefgh" first would leave "ij" dangling from the
        // longer value. Longest-first ordering is what prevents that.
        let r = SecretRedactor(secrets: [
            (name: "short", value: "abcdefgh"),
            (name: "long", value: "abcdefghij")
        ])
        XCTAssertEqual(r.redactKnownValues("abcdefghij"), "[secret:long]")
    }

    func testValuesShorterThanTheMinimumAreIgnored() {
        let r = SecretRedactor(secrets: [(name: "tiny", value: "abc")])
        XCTAssertEqual(r.redactKnownValues("abc def abc"), "abc def abc")
        XCTAssertTrue(r.isEmpty, "a redactor holding only sub-minimum values has nothing to do")
    }

    func testCredentialPatternsAreMatchedMidLine() {
        let out = SecretRedactor.redactCredentialPatterns("RESEND_API_KEY=re_abcdefghijklmnop rest")
        XCTAssertEqual(out, "RESEND_API_KEY=[redacted] rest")
    }

    func testEachCredentialPatternIsCovered() {
        let samples = [
            "sk-abcdefghijklmnopqrst",
            "sk_live_abcdefghijklmnop",
            "pk_live_abcdefghijklmnop",
            "re_abcdefghijklmnop",
            "ghp_" + String(repeating: "a", count: 36),
            "gho_" + String(repeating: "a", count: 36),
            "github_pat_" + String(repeating: "a", count: 22),
            "AKIAIOSFODNN7EXAMPLE",
            "ASIAIOSFODNN7EXAMPLE",
            "appl_abcdefghijklmnop",
            "xoxb-1234567890-abc",
            "xoxp-1234567890-abc",
            "hooks.slack.com/services/T00/B00/XXXXXXXX",
            "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NSJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c",
            """
            -----BEGIN RSA PRIVATE KEY-----
            MIIEowIBAAKCAQEAxGgVsecretbodyline1
            Ahk9secretbodyline2==
            -----END RSA PRIVATE KEY-----
            """
        ]
        for sample in samples {
            let out = SecretRedactor.redactCredentialPatterns("prefix \(sample) suffix")
            XCTAssertTrue(out.contains("[redacted]"), "pattern not caught: \(sample)")
            XCTAssertFalse(out.contains(sample), "value survived redaction: \(sample)")
        }
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(SecretRedactor.redactCredentialPatterns("git commit -m 'fix the thing'"),
                       "git commit -m 'fix the thing'")
    }

    func testRedactAppliesBothPasses() {
        let r = SecretRedactor(secrets: [(name: "mine", value: "zzzzzzzzzzzz")])
        let out = r.redact("A=zzzzzzzzzzzz B=sk-abcdefghijklmnopqrst")
        XCTAssertEqual(out, "A=[secret:mine] B=[redacted]")
    }

    func testDeepWalkPreservesStructureAndReplacesOnlyStrings() throws {
        let input: [String: Any] = [
            "stdout": "key=abcdefghij",
            "stderr": "",
            "interrupted": false,
            "nested": ["deep": ["abcdefghij", 42]]
        ]
        let out = try XCTUnwrap(
            SecretRedactor.redactStrings(in: input, using: { $0.replacingOccurrences(of: "abcdefghij", with: "X") })
            as? [String: Any]
        )
        XCTAssertEqual(out["stdout"] as? String, "key=X")
        XCTAssertEqual(out["stderr"] as? String, "")
        XCTAssertEqual(out["interrupted"] as? Bool, false)
        let nested = try XCTUnwrap(out["nested"] as? [String: Any])
        let deep = try XCTUnwrap(nested["deep"] as? [Any])
        XCTAssertEqual(deep[0] as? String, "X")
        XCTAssertEqual(deep[1] as? Int, 42)
    }

    func testPEMPrivateKeyIsRedactedWholeNotJustItsBanner() {
        // The banner-only pattern this replaced left the key body and the
        // footer in the clear while the output still showed [redacted].
        let pem = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEowIBAAKCAQEAxGgVsecretbodyline1
        Ahk9secretbodyline2==
        -----END RSA PRIVATE KEY-----
        """
        let out = SecretRedactor.redactCredentialPatterns("before\n\(pem)\nafter")
        XCTAssertEqual(out, "before\n[redacted]\nafter")
        XCTAssertFalse(out.contains("secretbodyline1"))
        XCTAssertFalse(out.contains("END RSA PRIVATE KEY"))
    }

    func testTruncatedPEMWithoutEndMarkerIsStillRedacted() {
        // Fail-safe: a key body cut off mid-stream must not escape because
        // its footer never arrived.
        let out = SecretRedactor.redactCredentialPatterns("x\n-----BEGIN PRIVATE KEY-----\nMIIEbodylinehere\n")
        XCTAssertFalse(out.contains("MIIEbodylinehere"))
        XCTAssertTrue(out.contains("[redacted]"))
    }

    func testThreeSegmentJWTIsRedactedIncludingItsSignature() {
        let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NSJ9.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let out = SecretRedactor.redactCredentialPatterns("Bearer \(jwt) end")
        XCTAssertEqual(out, "Bearer [redacted] end")
    }

    func testUnsignedJWTWithEmptyThirdSegmentIsRedacted() {
        XCTAssertEqual(SecretRedactor.redactCredentialPatterns("eyJhbGciOiJub25lIn0.eyJhIjoxfQ. rest"),
                       "[redacted] rest")
    }
}
