import XCTest
@testable import OpusArtifactsKit

/// Pure string in, values out. No disk, no AppKit. Existence filtering is
/// ArtifactClassifier's job (Task 4), so these tests deliberately accept
/// tokens that will later be rejected: this scanner's contract is "every
/// plausible candidate", not "every real file".
final class TextArtifactScannerTests: XCTestCase {

    // MARK: paths

    func testSingleAbsolutePath() {
        XCTAssertEqual(TextArtifactScanner.paths(in: "written to /tmp/a.png ok"),
                       ["/tmp/a.png"])
    }

    func testTwoPathsOnOneLine() {
        XCTAssertEqual(TextArtifactScanner.paths(in: "moved src/a.swift to src/b.swift"),
                       ["src/a.swift", "src/b.swift"])
    }

    func testSurroundingPunctuationIsNotPartOfTheToken() {
        XCTAssertEqual(TextArtifactScanner.paths(in: "see (src/a.swift:3), done"),
                       ["src/a.swift"])
    }

    func testTildePathIsReturnedUnexpanded() {
        // Expansion belongs to PathDetector.resolvePath, which needs a cwd.
        XCTAssertEqual(TextArtifactScanner.paths(in: "in ~/Desktop/kit/"),
                       ["~/Desktop/kit/"])
    }

    func testShortTokensAndBareWordsAreRejected() {
        XCTAssertEqual(TextArtifactScanner.paths(in: "a bare sentence with no path"), [])
    }

    func testTokenWithoutSlashOrDotIsRejected() {
        XCTAssertEqual(TextArtifactScanner.paths(in: "Makefile Dockerfile LICENSE"), [])
    }

    func testVersionNumberIsAcceptedHereAndKilledLaterByDisk() {
        // Documents the deliberate split of responsibility. v1.2.3 has a dot,
        // so it passes the scan; ArtifactClassifier drops it because nothing
        // exists at that path.
        XCTAssertEqual(TextArtifactScanner.paths(in: "bumped to v1.2.3"), ["v1.2.3"])
    }

    func testPathsIgnoreUrls() {
        // The URL scanner owns these. Returning "//example.com/x" here would
        // be worse than nothing: resolvePath treats a leading slash as
        // absolute, so it would resolve to a real-looking path.
        XCTAssertEqual(TextArtifactScanner.paths(in: "at https://example.com/x.png now"), [])
    }

    // MARK: urls

    func testUrlAtEndOfSentence() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "live at https://sitename.xyz."),
                       ["https://sitename.xyz"])
    }

    func testUrlInParentheses() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "(see https://vercel.com/docs) next"),
                       ["https://vercel.com/docs"])
    }

    func testUrlKeepsBalancedTrailingParen() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "https://en.wikipedia.org/wiki/A_(b)"),
                       ["https://en.wikipedia.org/wiki/A_(b)"])
    }

    func testTwoUrlsOnOneLine() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "http://a.dev and https://b.dev/x"),
                       ["http://a.dev", "https://b.dev/x"])
    }

    func testQueryStringIsPreserved() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "https://a.dev/p?token=abc&x=1 done"),
                       ["https://a.dev/p?token=abc&x=1"])
    }

    func testBareSchemeSeparatorIsNotAUrl() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "the :// separator"), [])
    }

    func testNonHttpSchemeIsIgnored() {
        XCTAssertEqual(TextArtifactScanner.urls(in: "ftp://a.dev/x and file:///tmp/y"), [])
    }
}
