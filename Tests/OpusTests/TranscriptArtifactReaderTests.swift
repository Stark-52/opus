import XCTest
@testable import OpusArtifactsKit

final class TranscriptArtifactReaderTests: XCTestCase {
    private var root: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        transcript = root.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: transcript.path, contents: nil)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Append one assistant line naming `name`, after creating that file so
    /// the classifier keeps it.
    private func appendLine(naming name: String) throws {
        let target = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: target)
        let line = """
        {"type":"assistant","cwd":"\(root.path)","message":{"content":[\
        {"type":"tool_use","name":"Write","input":{"file_path":"\(target.path)"}}]}}

        """
        let handle = try FileHandle(forWritingTo: transcript)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
    }

    private func names(_ result: TranscriptReadResult) -> [String] {
        result.artifacts.map { $0.displayName }
    }

    func testFirstReadPicksUpEverythingFromZero() throws {
        try appendLine(naming: "a.md")
        try appendLine(naming: "b.md")
        let out = TranscriptArtifactReader.read(url: transcript, from: 0, existing: [])
        XCTAssertEqual(names(out), ["b.md", "a.md"])
        XCTAssertEqual(out.offset, UInt64(try Data(contentsOf: transcript).count))
    }

    func testSecondReadOnlySeesTheNewBytes() throws {
        try appendLine(naming: "a.md")
        let first = TranscriptArtifactReader.read(url: transcript, from: 0, existing: [])
        try appendLine(naming: "b.md")
        let second = TranscriptArtifactReader.read(
            url: transcript, from: first.offset, existing: first.artifacts)
        XCTAssertEqual(names(second), ["b.md", "a.md"])
        XCTAssertGreaterThan(second.offset, first.offset)
    }

    func testNoNewBytesReturnsTheSameListAndOffset() throws {
        try appendLine(naming: "a.md")
        let first = TranscriptArtifactReader.read(url: transcript, from: 0, existing: [])
        let second = TranscriptArtifactReader.read(
            url: transcript, from: first.offset, existing: first.artifacts)
        XCTAssertEqual(second.artifacts, first.artifacts)
        XCTAssertEqual(second.offset, first.offset)
    }

    func testTruncatedFileRewindsAndRereadsEverything() throws {
        // A transcript smaller than the stored offset means the file was
        // replaced or rotated. Resuming from the old offset would read
        // garbage or nothing at all, silently and forever.
        try appendLine(naming: "a.md")
        let out = TranscriptArtifactReader.read(url: transcript, from: 999_999, existing: [])
        XCTAssertEqual(names(out), ["a.md"])
    }

    func testMissingFileIsNotAnError() {
        let out = TranscriptArtifactReader.read(
            url: root.appendingPathComponent("nope.jsonl"), from: 0, existing: [])
        XCTAssertEqual(out.artifacts, [])
        XCTAssertEqual(out.offset, 0)
    }

    func testPartialTrailingLineIsNotConsumed() throws {
        // The transcript is written by another process. A half-written last
        // line must not be parsed, and must not advance the offset past
        // itself, or its completed form is lost forever.
        try appendLine(naming: "a.md")
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"type":"assistant","cw"#.utf8))
        try handle.close()

        let out = TranscriptArtifactReader.read(url: transcript, from: 0, existing: [])
        XCTAssertEqual(names(out), ["a.md"])
        // Offset stops at the last complete newline, not at end of file.
        XCTAssertLessThan(out.offset, UInt64(try Data(contentsOf: transcript).count))
    }

    func testDeletedFileDisappearsFromTheList() throws {
        try appendLine(naming: "gone.md")
        let first = TranscriptArtifactReader.read(url: transcript, from: 0, existing: [])
        XCTAssertEqual(names(first), ["gone.md"])

        try FileManager.default.removeItem(at: root.appendingPathComponent("gone.md"))
        let second = TranscriptArtifactReader.read(
            url: transcript, from: first.offset, existing: first.artifacts)
        XCTAssertEqual(names(second), [])
    }
}
