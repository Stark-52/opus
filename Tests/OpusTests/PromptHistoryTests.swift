import XCTest
@testable import Opus
@testable import OpusSecretsKit

final class PromptHistoryTests: XCTestCase {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    func testParsesAPlainPrompt() {
        let e = PromptHistory.parse(line: line(#"{"display":"refactor le parser","pastedContents":{},"timestamp":1772230832330,"project":"/Users/x/proj","sessionId":"abc"}"#))
        XCTAssertEqual(e?.text, "refactor le parser")
        XCTAssertEqual(e?.project, "/Users/x/proj")
        // Brief's literal `XCTAssertEqual(e?.timestamp.timeIntervalSince1970,
        // 1772230832.330, accuracy: 0.01)` does not compile — XCTest's
        // `accuracy:` overload requires non-optional FloatingPoint on both
        // sides, and optional chaining makes the left side `Double?`. `?? 0`
        // keeps the same pass/fail behavior (0 fails the accuracy check just
        // as loudly as a literal nil would) while typechecking.
        XCTAssertEqual(e?.timestamp.timeIntervalSince1970 ?? 0, 1772230832.330, accuracy: 0.01)
    }

    func testPastedPlaceholderIsReplacedByTheRealContent() {
        // `display` is only a placeholder when the user pasted; the real text
        // lives in pastedContents. The palette must insert what was pasted.
        let raw = #"{"display":"[Pasted text #1 +19 lines]","pastedContents":{"1":{"id":1,"type":"text","content":"ligne A\nligne B"}},"timestamp":1,"project":"/p","sessionId":"s"}"#
        XCTAssertEqual(PromptHistory.parse(line: line(raw))?.text, "ligne A\nligne B")
    }

    func testEmptyDisplayIsRejected() {
        XCTAssertNil(PromptHistory.parse(line: line(#"{"display":"","pastedContents":{},"timestamp":1,"project":"/p","sessionId":"s"}"#)))
    }

    func testMalformedLineIsNil() {
        XCTAssertNil(PromptHistory.parse(line: line("{not json")))
    }

    func testMissingProjectFallsBackToEmptyString() {
        let e = PromptHistory.parse(line: line(#"{"display":"x","timestamp":1,"sessionId":"s"}"#))
        XCTAssertEqual(e?.project, "")
        XCTAssertEqual(e?.text, "x")
    }

    // MARK: - PromptHistory.load
    //
    // FINDING (b), v1.6 backlog task-1 fix round: `load` had ZERO committed
    // tests — a prior reviewer wrote six, ran them green, then deleted them
    // instead of committing (see the fix brief). Restored below, covering
    // exactly the six cases called out, plus one extra proving the FINDING
    // (c) doc-comment correction on `load` itself: a single record LARGER
    // than the tail window is silently dropped, not "impossible".

    /// Writes `contents` to a fresh temp file and returns its URL. Each test
    /// gets its own subdirectory (named with a UUID) so parallel test runs
    /// never collide on the same path.
    private func makeHistoryFile(_ contents: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.jsonl")
        try! contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func historyRecord(_ text: String, timestampMillis: Double) -> String {
        #"{"display":"\#(text)","pastedContents":{},"timestamp":\#(timestampMillis),"project":"/p","sessionId":"s"}"#
    }

    func testLoadOrdersPastedContentsByNumericKeyNotStringOrder() {
        // Keys "1","2","10" sort as "1","10","2" under plain string
        // comparison — `load` must join paste #1, #2, #10 in that numeric
        // order, matching the order the user actually pasted them.
        let raw = #"{"display":"[Pasted #1][Pasted #2][Pasted #10]","pastedContents":{"1":{"id":1,"type":"text","content":"un"},"2":{"id":2,"type":"text","content":"deux"},"10":{"id":10,"type":"text","content":"dix"}},"timestamp":1000,"project":"/p","sessionId":"s"}"#
        let entries = PromptHistory.load(url: makeHistoryFile(raw + "\n"))
        XCTAssertEqual(entries.map(\.text), ["un\ndeux\ndix"])
    }

    func testLoadDedupeKeepsTheMostRecentOccurrence() {
        let lines = [
            historyRecord("refactor le parser", timestampMillis: 1000),
            historyRecord("other prompt", timestampMillis: 2000),
            historyRecord("refactor le parser", timestampMillis: 3000),   // re-typed later
        ].joined(separator: "\n")
        let entries = PromptHistory.load(url: makeHistoryFile(lines + "\n"))
        XCTAssertEqual(entries.count, 2)
        // Newest-first, and the surviving "refactor le parser" is the
        // 3000ms occurrence, not the 1000ms one it deduped away.
        XCTAssertEqual(entries[0].text, "refactor le parser")
        XCTAssertEqual(entries[0].timestamp.timeIntervalSince1970, 3.0, accuracy: 0.001)
        XCTAssertEqual(entries[1].text, "other prompt")
    }

    func testLoadFileSmallerThanTheWindowKeepsTheFirstLine() {
        // Total size is well under tailBudgetBytes (512KB) — tailStart stays
        // 0, so byte 0 IS the start of a real line and must NOT be dropped
        // as a "leading partial line".
        let lines = [
            historyRecord("oldest prompt", timestampMillis: 1000),
            historyRecord("middle prompt", timestampMillis: 2000),
            historyRecord("newest prompt", timestampMillis: 3000),
        ].joined(separator: "\n")
        XCTAssertLessThan(lines.utf8.count, PromptHistory.tailBudgetBytes)
        let entries = PromptHistory.load(url: makeHistoryFile(lines + "\n"))
        XCTAssertEqual(entries.map(\.text), ["newest prompt", "middle prompt", "oldest prompt"])
    }

    func testLoadMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PromptHistoryTests-\(UUID().uuidString)")
            .appendingPathComponent("does-not-exist.jsonl")
        XCTAssertEqual(PromptHistory.load(url: url), [])
    }

    func testLoadEmptyFileReturnsEmpty() {
        XCTAssertEqual(PromptHistory.load(url: makeHistoryFile("")), [])
    }

    func testLoadFileLargerThanTheWindowDropsTheLeadingPartialLine() {
        // A large filler record pushes the file past tailBudgetBytes (512KB)
        // so the tail window's start lands mid-way through it — the leading
        // "line" in the window is a truncated fragment of the filler
        // record, not a real record boundary, and must be dropped rather
        // than parsed as (or leaking through as) a corrupt entry.
        let filler = historyRecord(String(repeating: "x", count: 700_000), timestampMillis: 500)
        let real = [
            historyRecord("real prompt one", timestampMillis: 1000),
            historyRecord("real prompt two", timestampMillis: 2000),
        ]
        let contents = ([filler] + real).joined(separator: "\n") + "\n"
        XCTAssertGreaterThan(contents.utf8.count, PromptHistory.tailBudgetBytes)
        let entries = PromptHistory.load(url: makeHistoryFile(contents))
        // Only the two real, fully-in-window records come back — no
        // malformed/partial entry from the filler's truncated fragment.
        XCTAssertEqual(entries.map(\.text), ["real prompt two", "real prompt one"])
    }

    func testLoadSilentlyDropsARecordLargerThanTheWindowItself() {
        // FINDING (c): the doc comment on `load` used to claim a record
        // bigger than the tail window can't happen. It can (a prompt with
        // enough pasted content), and when it does, it is silently dropped
        // in full — this isolates that exact case: one oversized record,
        // nothing else in the file for it to be confused with.
        let filler = historyRecord(String(repeating: "y", count: 600_000), timestampMillis: 500)
        XCTAssertGreaterThan(filler.utf8.count, PromptHistory.tailBudgetBytes)
        let entries = PromptHistory.load(url: makeHistoryFile(filler + "\n"))
        XCTAssertEqual(entries, [])
    }

    // MARK: - Redaction

    private func historyLine(_ display: String) -> Data {
        Data("""
        {"display":"\(display)","timestamp":1700000000000,"project":"/tmp/p"}
        """.utf8)
    }

    func testParseRedactsCredentialPatternsByDefault() throws {
        let entry = try XCTUnwrap(PromptHistory.parse(line: historyLine("RESEND_API_KEY=re_abcdefghijklmnop")))
        XCTAssertEqual(entry.text, "RESEND_API_KEY=[redacted]",
                       "the credential is stripped, the surrounding prompt is kept")
    }

    func testParseKeepsOrdinaryPromptsIntact() throws {
        let entry = try XCTUnwrap(PromptHistory.parse(line: historyLine("fix the login bug")))
        XCTAssertEqual(entry.text, "fix the login bug")
    }

    func testParseRedactsAKnownStoredValueMidLine() throws {
        let redactor = SecretRedactor(secrets: [(name: "mine", value: "zzzzzzzzzzzz")])
        let entry = try XCTUnwrap(PromptHistory.parse(line: historyLine("KEY=zzzzzzzzzzzz voilà"), redactor: redactor))
        XCTAssertEqual(entry.text, "KEY=[secret:mine] voilà")
    }

    func testParseDropsALineLeftEmptyByRedaction() {
        XCTAssertNil(PromptHistory.parse(line: historyLine("sk-abcdefghijklmnopqrst")),
                     "a prompt that was nothing but a credential has no value once redacted")
    }
}
