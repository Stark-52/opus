import XCTest
@testable import OpusScriptsKit

/// The buffer holds what a running script has printed so far. It is bounded:
/// a script left running for a week must not grow Opus's memory without limit.
final class ScriptOutputBufferTests: XCTestCase {
    func testAppendedTextIsReadBackInOrder() {
        var buffer = ScriptOutputBuffer()
        buffer.append("premier\n")
        buffer.append("second\n")
        XCTAssertEqual(buffer.text, "premier\nsecond\n")
    }

    func testTheBufferIsBoundedAndDropsTheOLDESTOutput() {
        var buffer = ScriptOutputBuffer(limit: 20)
        buffer.append(String(repeating: "a", count: 15))
        buffer.append(String(repeating: "b", count: 15))
        XCTAssertEqual(buffer.text.count, 20)
        XCTAssertTrue(buffer.text.hasSuffix(String(repeating: "b", count: 15)),
                      "the tail is what the user is watching; the head is what gets dropped")
        XCTAssertTrue(buffer.truncated, "silently dropping output would misrepresent the run")
    }

    func testASingleAppendLargerThanTheLimitKeepsOnlyItsTail() {
        var buffer = ScriptOutputBuffer(limit: 10)
        buffer.append("xxxxxSIBLE12345")   // 15 chars; the last 10 survive
        XCTAssertEqual(buffer.text, "SIBLE12345")
        XCTAssertTrue(buffer.truncated)
    }

    func testClearingResetsTheTruncationFlagToo() {
        var buffer = ScriptOutputBuffer(limit: 4)
        buffer.append("abcdefgh")
        XCTAssertTrue(buffer.truncated)
        buffer.clear()
        XCTAssertEqual(buffer.text, "")
        XCTAssertFalse(buffer.truncated, "a fresh run must not inherit the previous run's warning")
    }

    // MARK: ANSI

    /// Scripts colour their output and draw progress bars. The panel renders
    /// plain text, so the escape sequences have to go or they show up as
    /// literal garbage like "[0;32mOK[0m".
    func testColourSequencesAreStripped() {
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("\u{1B}[0;32mOK\u{1B}[0m"), "OK")
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("\u{1B}[1;31merreur\u{1B}[0m fin"), "erreur fin")
    }

    func testCursorAndEraseSequencesAreStripped() {
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("a\u{1B}[2Kb"), "ab")
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("a\u{1B}[Hb"), "ab")
    }

    /// A progress bar rewrites one line with carriage returns. Keeping them
    /// makes the log look like one endless line; each rewrite becomes its own
    /// line instead, which is honest and readable.
    func testCarriageReturnsBecomeNewlinesRatherThanVanishing() {
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("10%\r50%\r100%\n"), "10%\n50%\n100%\n")
    }

    func testACarriageReturnAlreadyFollowedByANewlineIsNotDoubled() {
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("ligne\r\nsuivante"), "ligne\nsuivante")
    }

    func testPlainTextIsUntouched() {
        let plain = "rien à nettoyer ici — accents compris\n"
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi(plain), plain)
    }

    func testALoneEscapeAtTheEndDoesNotCrashOrEatTheBuffer() {
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("texte\u{1B}"), "texte")
        XCTAssertEqual(ScriptOutputBuffer.stripAnsi("texte\u{1B}["), "texte")
    }
}
