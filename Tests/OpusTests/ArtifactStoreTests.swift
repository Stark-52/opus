import XCTest
@testable import OpusArtifactsKit

final class ArtifactStoreTests: XCTestCase {

    private func file(_ name: String) -> Artifact {
        Artifact(key: "/tmp/\(name)", kind: .file, resolvedPath: "/tmp/\(name)", urlString: nil)
    }

    private func keys(_ list: [Artifact]) -> [String] {
        list.map { ($0.resolvedPath.map { p in (p as NSString).lastPathComponent }) ?? $0.key }
    }

    func testIncomingTranscriptOrderBecomesNewestFirst() {
        // `incoming` arrives in transcript order, oldest first. The drawer
        // shows newest first, so the batch is reversed at the head.
        let out = ArtifactStore.merge(existing: [], incoming: [file("a"), file("b"), file("c")])
        XCTAssertEqual(keys(out), ["c", "b", "a"])
    }

    func testExistingListIsPreservedBelowTheNewBatch() {
        let existing = ArtifactStore.merge(existing: [], incoming: [file("a"), file("b")])
        let out = ArtifactStore.merge(existing: existing, incoming: [file("c")])
        XCTAssertEqual(keys(out), ["c", "b", "a"])
    }

    func testRepeatMentionMovesToTheTopWithoutDuplicating() {
        let existing = ArtifactStore.merge(existing: [], incoming: [file("a"), file("b"), file("c")])
        let out = ArtifactStore.merge(existing: existing, incoming: [file("a")])
        XCTAssertEqual(keys(out), ["a", "c", "b"])
    }

    func testDuplicatesWithinOneBatchCollapseToTheLastMention() {
        let out = ArtifactStore.merge(existing: [], incoming: [file("a"), file("b"), file("a")])
        XCTAssertEqual(keys(out), ["a", "b"])
    }

    func testCapacityDropsTheOldest() {
        let out = ArtifactStore.merge(
            existing: [], incoming: [file("a"), file("b"), file("c")], capacity: 2)
        XCTAssertEqual(keys(out), ["c", "b"])
    }

    func testHttpAndHttpsSurviveAsTwoEntries() {
        let a = Artifact(key: "http://a.dev", kind: .url, resolvedPath: nil, urlString: "http://a.dev")
        let b = Artifact(key: "https://a.dev", kind: .url, resolvedPath: nil, urlString: "https://a.dev")
        XCTAssertEqual(ArtifactStore.merge(existing: [], incoming: [a, b]).count, 2)
    }

    func testEmptyIncomingLeavesTheListUntouched() {
        let existing = ArtifactStore.merge(existing: [], incoming: [file("a")])
        XCTAssertEqual(ArtifactStore.merge(existing: existing, incoming: []), existing)
    }
}
