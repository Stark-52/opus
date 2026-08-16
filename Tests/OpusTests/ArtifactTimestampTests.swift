import XCTest
@testable import OpusArtifactsKit

/// Ordering used to be "position in the transcript", which stops meaning
/// anything the moment two sessions are merged into one drawer. Transcript
/// entries carry an ISO8601 timestamp to the millisecond, so that becomes
/// the clock.
final class ArtifactTimestampTests: XCTestCase {

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)!
    }

    private func make(_ name: String, _ iso: String?) -> Artifact {
        Artifact(key: "/tmp/\(name)", kind: .file, resolvedPath: "/tmp/\(name)",
                 urlString: nil, timestamp: iso.map(at))
    }

    func testTimestampIsParsedFromATranscriptLine() {
        let line = Data("""
        {"type":"assistant","cwd":"/tmp","timestamp":"2026-08-16T14:01:10.280Z","message":{"content":[
          {"type":"tool_use","name":"Write","input":{"file_path":"/tmp/a.md"}}
        ]}}
        """.utf8)
        let candidates = TranscriptArtifactExtractor.candidates(fromLine: line)
        XCTAssertEqual(candidates.first?.timestamp, at("2026-08-16T14:01:10.280Z"))
    }

    func testALineWithoutATimestampStillYieldsItsCandidates() {
        // Older transcripts, and any entry shape that omits it. Dropping the
        // artifact because the clock is missing would be worse than ordering
        // it conservatively.
        let line = Data("""
        {"type":"assistant","cwd":"/tmp","message":{"content":[
          {"type":"tool_use","name":"Write","input":{"file_path":"/tmp/a.md"}}
        ]}}
        """.utf8)
        let candidates = TranscriptArtifactExtractor.candidates(fromLine: line)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertNil(candidates.first?.timestamp)
    }

    func testMergeOrdersByTimestampNewestFirstAcrossSources() {
        // The whole point: two sessions' artifacts interleave correctly
        // instead of one batch simply landing on top of the other.
        let sessionA = [make("a1", "2026-08-16T10:00:00.000Z"),
                        make("a2", "2026-08-16T12:00:00.000Z")]
        let sessionB = [make("b1", "2026-08-16T11:00:00.000Z")]
        let merged = ArtifactStore.merge(existing: sessionA, incoming: sessionB)
        XCTAssertEqual(merged.map(\.displayName), ["a2", "b1", "a1"])
    }

    func testUndatedArtifactsSortAfterDatedOnes() {
        // An artifact with no clock cannot claim to be recent.
        let merged = ArtifactStore.merge(
            existing: [make("undated", nil)],
            incoming: [make("dated", "2026-08-16T10:00:00.000Z")])
        XCTAssertEqual(merged.map(\.displayName), ["dated", "undated"])
    }

    func testDeduplicationKeepsTheNewerTimestamp() {
        // The same file written twice is one row, dated by its latest write.
        let older = make("f", "2026-08-16T10:00:00.000Z")
        let newer = make("f", "2026-08-16T12:00:00.000Z")
        let merged = ArtifactStore.merge(existing: [older], incoming: [newer])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.timestamp, at("2026-08-16T12:00:00.000Z"))
    }

    func testOrderIsStableForIdenticalTimestamps() {
        let a = make("a", "2026-08-16T10:00:00.000Z")
        let b = make("b", "2026-08-16T10:00:00.000Z")
        let merged = ArtifactStore.merge(existing: [], incoming: [a, b])
        XCTAssertEqual(merged.count, 2)
    }
}
