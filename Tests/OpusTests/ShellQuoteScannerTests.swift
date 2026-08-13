import XCTest
@testable import OpusSecretsKit

/// Focused tests for the state machine CommandSubstitutionRewriter leans on
/// to decide how a placeholder must be rewritten. This is the piece most
/// likely to have an edge case, so it gets tested directly against the
/// scanner rather than only indirectly through HookRunner.
///
/// Each fixture marks the position to query with `@`. `context(in:at:)`
/// only looks at characters STRICTLY BEFORE the given index, so the marker
/// itself never needs to be stripped out first — leaving it in place is
/// simpler and avoids reusing a String.Index across two different String
/// values.
final class ShellQuoteScannerTests: XCTestCase {
    private func context(_ fixture: String) -> ShellQuoteContext {
        guard let markerIndex = fixture.firstIndex(of: "@") else {
            XCTFail("fixture must contain '@' marking the query position")
            return .outside
        }
        return ShellQuoteScanner.context(in: fixture, at: markerIndex)
    }

    private func position(_ fixture: String) -> ShellPosition {
        guard let markerIndex = fixture.firstIndex(of: "@") else {
            XCTFail("fixture must contain '@' marking the query position")
            return ShellPosition(quoteContext: .outside, pendingEscape: false)
        }
        return ShellQuoteScanner.position(in: fixture, at: markerIndex)
    }

    func testOutsideAnyQuotes() {
        XCTAssertEqual(context("echo @hi"), .outside)
    }

    func testInsideDoubleQuotes() {
        XCTAssertEqual(context("echo \"a @b\""), .doubleQuoted)
    }

    func testInsideSingleQuotes() {
        XCTAssertEqual(context("echo 'a @b'"), .singleQuoted)
    }

    func testClosingADoubleQuotedRegionReturnsToOutside() {
        XCTAssertEqual(context("echo \"hi\" @after"), .outside)
    }

    func testClosingASingleQuotedRegionReturnsToOutside() {
        XCTAssertEqual(context("echo 'hi' @after"), .outside)
    }

    func testAnEmptyDoubleQuotedRegionClosesImmediately() {
        XCTAssertEqual(context("echo \"\" @after"), .outside)
    }

    func testEscapedDoubleQuoteOutsideQuotesDoesNotOpenARegion() {
        // Shell text: echo \" @after — a literal, escaped quote outside any
        // quoted region must not be mistaken for an opener.
        XCTAssertEqual(context("echo \\\" @after"), .outside)
    }

    func testEscapedDoubleQuoteInsideDoubleQuotesDoesNotCloseTheRegion() {
        // Shell text: echo "a \" @b" — the escaped quote inside the region
        // does not end it.
        XCTAssertEqual(context("echo \"a \\\" @b\""), .doubleQuoted)
    }

    func testSingleQuoteHasNoSpecialMeaningInsideDoubleQuotes() {
        // Shell text: echo "it's @fine" — POSIX gives an apostrophe no
        // meaning inside "..."; it must not be treated as an opener/closer.
        XCTAssertEqual(context("echo \"it's @fine\""), .doubleQuoted)
    }

    func testDoubleQuoteHasNoSpecialMeaningInsideSingleQuotes() {
        // Shell text: echo '"x" @y' — POSIX gives NOTHING special meaning
        // inside '...', including a double quote character.
        XCTAssertEqual(context("echo '\"x\" @y'"), .singleQuoted)
    }

    func testBackslashInsideSingleQuotesDoesNotEscapeTheClosingQuote() {
        // Shell text: echo '\' @after — POSIX single quotes give NO special
        // meaning to backslash at all, so '\' is a COMPLETE, already-closed
        // three-character region containing one backslash, not an
        // unterminated one. A scanner that let backslash escape here would
        // wrongly report .singleQuoted at the marker instead of .outside.
        XCTAssertEqual(context("echo '\\' @after"), .outside)
    }

    func testBackslashOutsideQuotesEscapesTheNextCharacter() {
        // Sanity check on the flip side: outside quotes, \' DOES suppress
        // the quote it precedes from opening a region.
        XCTAssertEqual(context("echo \\' @after"), .outside)
    }

    func testBackslashInsideDoubleQuotesEscapesTheNextCharacter() {
        // Shell text: echo "a \\ @b" — a backslash inside double quotes
        // still escapes the character right after it (here, another
        // backslash), so the region does not end early.
        XCTAssertEqual(context("echo \"a \\\\ @b\""), .doubleQuoted)
    }

    // MARK: pendingEscape — added after a review caught a splice landing
    // right on top of a live, unconsumed backslash (see
    // CommandSubstitutionRewriterTests for the real-shell proof of the bug
    // this exists to prevent).

    func testPendingEscapeIsTrueImmediatelyAfterABackslashOutsideQuotes() {
        // Shell text: echo \@after — zero gap between the backslash and the
        // query position, so whatever sits there is the escape's target.
        let p = position("echo \\@after")
        XCTAssertEqual(p.quoteContext, .outside)
        XCTAssertTrue(p.pendingEscape)
    }

    func testPendingEscapeIsFalseWhenASpaceSeparatesTheBackslashFromTheQuery() {
        // Shell text: echo \ @after — the space is what the backslash
        // escapes; the position after it is a clean boundary.
        let p = position("echo \\ @after")
        XCTAssertEqual(p.quoteContext, .outside)
        XCTAssertFalse(p.pendingEscape)
    }

    func testPendingEscapeIsFalseAfterAnEvenNumberOfBackslashes() {
        // Shell text: echo \\@after — the pair cancels: the first
        // backslash's target IS the second one, so nothing is left pending.
        let p = position("echo \\\\@after")
        XCTAssertEqual(p.quoteContext, .outside)
        XCTAssertFalse(p.pendingEscape)
    }

    func testPendingEscapeIsTrueAfterAnOddNumberOfBackslashes() {
        // Shell text: echo \\\@after — three backslashes: the first pair
        // cancels, the third is live.
        let p = position("echo \\\\\\@after")
        XCTAssertEqual(p.quoteContext, .outside)
        XCTAssertTrue(p.pendingEscape)
    }

    func testPendingEscapeIsTrueImmediatelyAfterABackslashInsideDoubleQuotes() {
        // Shell text: echo "a\@b" — same zero-gap escape, this time inside
        // a double-quoted region.
        let p = position("echo \"a\\@b\"")
        XCTAssertEqual(p.quoteContext, .doubleQuoted)
        XCTAssertTrue(p.pendingEscape)
    }

    func testPendingEscapeIsAlwaysFalseInsideSingleQuotesEvenRightAfterABackslash() {
        // Shell text: echo '\@b' — backslash has no meaning inside single
        // quotes at all, so it can never leave anything pending there.
        let p = position("echo '\\@b'")
        XCTAssertEqual(p.quoteContext, .singleQuoted)
        XCTAssertFalse(p.pendingEscape)
    }
}
