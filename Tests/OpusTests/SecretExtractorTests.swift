import XCTest
@testable import OpusSecretsKit

final class SecretExtractorTests: XCTestCase {
    private func one(_ blob: String) -> SecretCandidate? {
        SecretExtractor.candidates(from: blob).first
    }

    func testEnvAssignment() {
        XCTAssertEqual(one("RESEND_API_KEY=re_live_abc123"),
                       SecretCandidate(suggestedName: "resend-api-key", value: "re_live_abc123"))
    }

    func testEnvAssignmentWithSpacesAndQuotes() {
        XCTAssertEqual(one("RESEND_API_KEY = \"re_live_abc123\""),
                       SecretCandidate(suggestedName: "resend-api-key", value: "re_live_abc123"))
        XCTAssertEqual(one("KEY='single'"),
                       SecretCandidate(suggestedName: "key", value: "single"))
    }

    func testExportPrefixIsStripped() {
        XCTAssertEqual(one("export STRIPE_SECRET=sk_live_xyz"),
                       SecretCandidate(suggestedName: "stripe-secret", value: "sk_live_xyz"))
    }

    func testColonFormYaml() {
        XCTAssertEqual(one("api_key: abcdef123456"),
                       SecretCandidate(suggestedName: "api-key", value: "abcdef123456"))
    }

    func testJsonForm() {
        XCTAssertEqual(one("  \"apiKey\": \"abcdef123456\","),
                       SecretCandidate(suggestedName: "apikey", value: "abcdef123456"))
    }

    func testBearerHeaderKeepsOnlyTheToken() {
        XCTAssertEqual(one("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9"),
                       SecretCandidate(suggestedName: "authorization", value: "eyJhbGciOiJIUzI1NiJ9"))
    }

    func testBareTokenHasNoSuggestedName() {
        XCTAssertEqual(one("re_live_abc123"),
                       SecretCandidate(suggestedName: "", value: "re_live_abc123"))
    }

    func testMultiLineBlobYieldsOneCandidatePerAssignment() {
        let blob = """
        # Resend
        RESEND_API_KEY=re_live_abc

        STRIPE_SECRET=sk_live_xyz
        """
        XCTAssertEqual(SecretExtractor.candidates(from: blob), [
            SecretCandidate(suggestedName: "resend-api-key", value: "re_live_abc"),
            SecretCandidate(suggestedName: "stripe-secret", value: "sk_live_xyz")
        ])
    }

    func testCRLFBlobStillSplitsIntoLines() {
        // Regression guard. Swift groups CR+LF into one Character, so
        // split(separator: "\n") returns the whole paste as a single line
        // and yields one bogus candidate instead of two. Verified:
        // "a\r\nb".contains("\n") == false.
        let blob = "RESEND_API_KEY=re_live_abc\r\nSTRIPE_SECRET=sk_live_xyz"
        XCTAssertEqual(SecretExtractor.candidates(from: blob), [
            SecretCandidate(suggestedName: "resend-api-key", value: "re_live_abc"),
            SecretCandidate(suggestedName: "stripe-secret", value: "sk_live_xyz")
        ])
    }

    func testCommentsAndBlankLinesAreSkipped() {
        XCTAssertEqual(SecretExtractor.candidates(from: "# just a comment\n\n   \n"), [])
    }

    func testLinesWithSpacesButNoAssignmentAreNotBareTokens() {
        // "this is prose" must not become a secret candidate.
        XCTAssertEqual(SecretExtractor.candidates(from: "this is prose"), [])
    }

    func testMaskedPreviewShowsShapeNotValue() {
        XCTAssertEqual(SecretExtractor.maskedPreview("re_live_abc123"), "re…23 (14 car.)")
        XCTAssertEqual(SecretExtractor.maskedPreview("abcd"), "…… (4 car.)")
    }

    func testBareURLIsNotSplitIntoKeyAndValue() {
        // A Slack webhook is a realistic paste. Filing it as name "https"
        // with the scheme stripped off the value would corrupt it silently.
        let url = "https://hooks.slack.com/services/T00/B00/XXXX"
        XCTAssertEqual(SecretExtractor.candidates(from: url),
                       [SecretCandidate(suggestedName: "", value: url)])
    }

    func testConnectionStringIsNotSplit() {
        let dsn = "postgres://user:pass@host:5432/db"
        XCTAssertEqual(SecretExtractor.candidates(from: dsn),
                       [SecretCandidate(suggestedName: "", value: dsn)])
    }

    func testWindowsPathIsNotSplit() {
        let path = "C:\\Users\\dev\\secrets.txt"
        XCTAssertEqual(SecretExtractor.candidates(from: path),
                       [SecretCandidate(suggestedName: "", value: path)])
    }

    func testEqualsSeparatedValueStartingWithSlashesIsStillAnAssignment() {
        // The URI guard is gated on the separator, so this must not regress.
        XCTAssertEqual(SecretExtractor.candidates(from: "PATH_PREFIX=//shared"),
                       [SecretCandidate(suggestedName: "path-prefix", value: "//shared")])
    }

    func testAtMostOneAuthSchemeIsStripped() {
        XCTAssertEqual(SecretExtractor.candidates(from: "Authorization: Bearer Token abc123"),
                       [SecretCandidate(suggestedName: "authorization", value: "Token abc123")])
    }

    func testAnEmptyAssignmentValueIsSkippedNotFiledAsABareToken() {
        // FOO= (nothing after the =) used to fail the assignment regex
        // (which required 1+ characters for the value), fall through to the
        // bare-token path, and get filed as a NAMELESS candidate whose
        // value was the literal string "FOO=".
        XCTAssertEqual(SecretExtractor.candidates(from: "FOO="), [])
    }

    func testAnEmptyColonFormValueIsAlsoSkipped() {
        XCTAssertEqual(SecretExtractor.candidates(from: "api_key:"), [])
    }

    func testShellHostileDetection() {
        XCTAssertFalse(SecretExtractor.isShellHostile("re_live_abc-123.XYZ"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has'quote"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has\"quote"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has$dollar"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has`tick"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has\\slash"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has\nnewline"))
        XCTAssertTrue(SecretExtractor.isShellHostile("has\r\ncrlf"),
                      "CRLF is a single Swift Character and is NOT a member of a set holding \\n and \\r separately")
    }
}
