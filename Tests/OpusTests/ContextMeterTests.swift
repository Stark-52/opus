import XCTest
@testable import Opus

final class ContextMeterTests: XCTestCase {
    private func data(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8)
    }

    /// A well-formed assistant/usage JSONL line, matching the real shape
    /// confirmed in ContextMeter.swift's header comment (extra fields the
    /// parser ignores included, so tests exercise the same shape production
    /// transcripts actually have).
    private func assistantLine(
        model: String?,
        input: Int,
        cacheCreation: Int,
        cacheRead: Int,
        output: Int = 15
    ) -> String {
        let modelField = model.map { #""model":"\#($0)","# } ?? ""
        return #"""
        {"type":"assistant","message":{\#(modelField)"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead),"output_tokens":\#(output),"service_tier":"standard"}}}
        """#
    }

    // MARK: usage(fromTranscriptTail:)

    func testAssistantRecordWithUsage_sumsInputCacheReadCacheCreation_ignoresOutput() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,   // dropped as the "partial first line"
            assistantLine(model: "claude-opus-4-8", input: 2, cacheCreation: 2752, cacheRead: 689241, output: 999999),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.tokens, 2 + 2752 + 689241)
        XCTAssertEqual(result?.limit, ContextMeter.defaultLimit)
    }

    func testMultipleUsageRecords_lastMatchWins() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: "claude-opus-4-8", input: 100, cacheCreation: 100, cacheRead: 100),
            assistantLine(model: "claude-opus-4-8", input: 200, cacheCreation: 200, cacheRead: 200),
            assistantLine(model: "claude-opus-4-8", input: 300, cacheCreation: 300, cacheRead: 300),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.tokens, 900)
    }

    /// Defensive case: a `usage` key missing entirely (not the real
    /// `<synthetic>` shape — see the two zeroed-usage tests below for that;
    /// this covers any record shape this parser hasn't seen in practice).
    func testAssistantRecordMissingUsageKeyEntirely_skipped_priorMatchStillWins() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: "claude-opus-4-8", input: 111, cacheCreation: 0, cacheRead: 0),
            #"{"type":"assistant","message":{"model":"claude-opus-4-8"}}"#,   // no usage object at all
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.tokens, 111)
    }

    /// The REAL `<synthetic>`-model shape (Fix round 1 — see file header):
    /// `usage` IS present, but every field is 0. Must be treated as a
    /// non-match, not as "the session is now at 0 tokens."
    func testZeroedSyntheticUsageRecordAfterReal_realOneWins() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: "claude-opus-4-8", input: 500, cacheCreation: 200, cacheRead: 300),
            assistantLine(model: "<synthetic>", input: 0, cacheCreation: 0, cacheRead: 0, output: 0),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.tokens, 1000)
    }

    func testTailWithOnlyZeroedUsageRecords_returnsNil() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: "<synthetic>", input: 0, cacheCreation: 0, cacheRead: 0, output: 0),
            assistantLine(model: "<synthetic>", input: 0, cacheCreation: 0, cacheRead: 0, output: 0),
        ])
        XCTAssertNil(ContextMeter.usage(fromTranscriptTail: tail))
    }

    func testMalformedLine_skipped() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            #"{"type":"assistant","message":{ this is not valid json"#,
            assistantLine(model: "claude-opus-4-8", input: 50, cacheCreation: 0, cacheRead: 0),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.tokens, 50)
    }

    func testOneMillionModelSuffix_usesOneMillionLimit() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: "claude-sonnet-4-20250514[1m]", input: 10, cacheCreation: 0, cacheRead: 0),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.limit, 1_000_000)
    }

    func testMissingModel_defaultsTo200k() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            assistantLine(model: nil, input: 10, cacheCreation: 0, cacheRead: 0),
        ])
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertEqual(result?.limit, 200_000)
    }

    /// The tail buffer's first "line" is dropped UNCONDITIONALLY, even when
    /// it's itself a well-formed, parseable assistant/usage record — same
    /// rule as SessionIndex.latestAiTitle. Constructed so this is the ONLY
    /// record in the buffer: if the drop didn't happen, the result would be
    /// this record's tokens instead of nil.
    func testFirstPartialLine_droppedUnconditionally() {
        let onlyRecord = assistantLine(model: "claude-opus-4-8", input: 42, cacheCreation: 0, cacheRead: 0)
        let tail = Data((onlyRecord + "\n").utf8)
        let result = ContextMeter.usage(fromTranscriptTail: tail)
        XCTAssertNil(result)
    }

    func testNoMatchingRecordsAnywhere_returnsNil() {
        let tail = data([
            #"{"type":"system","cwd":"/x"}"#,
            #"{"type":"user","message":{"role":"user","content":"hello"}}"#,
        ])
        XCTAssertNil(ContextMeter.usage(fromTranscriptTail: tail))
    }

    func testEmptyTail_noNewlineAtAll_returnsNil() {
        XCTAssertNil(ContextMeter.usage(fromTranscriptTail: Data("no newline here".utf8)))
    }
}
