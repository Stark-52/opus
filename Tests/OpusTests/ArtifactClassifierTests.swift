import XCTest
@testable import OpusArtifactsKit

/// Uses a real temporary directory rather than a FileManager stub: the
/// behaviour under test IS "what does the disk say", and a stub that
/// answers from a dictionary would be testing the stub.
final class ArtifactClassifierTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opus-artifacts-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // NSTemporaryDirectory() sits under /var/folders, and /var is a
        // symlink to /private/var. PathDetector.resolvePath ends in
        // standardizingPath, which resolves that, so an unresolved expected
        // value would never equal the resolved actual one and the test would
        // fail for a reason unrelated to what it tests. Resolve once here,
        // after the directory exists, and every comparison below lines up.
        root = root.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFile(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.path
    }

    private func makeDir(_ name: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    private func classify(_ payload: ArtifactCandidate.Payload, cwd: String? = nil) -> Artifact? {
        ArtifactClassifier.classify(ArtifactCandidate(payload: payload, cwd: cwd ?? root.path))
    }

    func testExistingFileIsAFile() throws {
        let path = try makeFile("note.md")
        let artifact = classify(.path(path))
        XCTAssertEqual(artifact?.kind, .file)
        XCTAssertEqual(artifact?.resolvedPath, path)
        XCTAssertEqual(artifact?.displayName, "note.md")
    }

    func testExistingDirectoryIsAFolder() throws {
        let path = try makeDir("drafts")
        XCTAssertEqual(classify(.path(path))?.kind, .folder)
    }

    func testExistingImageIsAnImage() throws {
        let path = try makeFile("hero.png")
        XCTAssertEqual(classify(.path(path))?.kind, .image)
    }

    func testMissingPathIsDropped() {
        XCTAssertNil(classify(.path(root.appendingPathComponent("nope.md").path)))
    }

    func testVersionNumberIsDropped() {
        // The whole reason text scanning is safe.
        XCTAssertNil(classify(.path("v1.2.3")))
    }

    func testRelativePathResolvesAgainstCwd() throws {
        _ = try makeFile("rel.md")
        let artifact = classify(.path("rel.md"))
        XCTAssertEqual(artifact?.resolvedPath, root.appendingPathComponent("rel.md").path)
    }

    func testTrailingSentenceDotIsRecovered() throws {
        let path = try makeFile("end.md")
        // "written to end.md." — the dot is part of the token charset.
        XCTAssertEqual(classify(.path(path + "."))?.resolvedPath, path)
    }

    func testUrlIsAlwaysKeptWithoutADiskCheck() {
        let artifact = classify(.url("https://a.dev/x"))
        XCTAssertEqual(artifact?.kind, .url)
        XCTAssertEqual(artifact?.urlString, "https://a.dev/x")
        XCTAssertNil(artifact?.resolvedPath)
    }

    func testUrlDedupKeyNormalisesHostCaseAndTrailingSlash() {
        XCTAssertEqual(classify(.url("https://A.dev/x/"))?.key,
                       classify(.url("https://a.dev/x"))?.key)
    }

    func testHttpAndHttpsAreDistinctKeys() {
        XCTAssertNotEqual(classify(.url("http://a.dev/x"))?.key,
                          classify(.url("https://a.dev/x"))?.key)
    }

    func testUrlQueryIsPreservedInBothKeyAndValue() {
        let artifact = classify(.url("https://a.dev/p?token=abc"))
        XCTAssertEqual(artifact?.urlString, "https://a.dev/p?token=abc")
        XCTAssertNotEqual(artifact?.key, classify(.url("https://a.dev/p"))?.key)
    }

    func testFileKeyIgnoresLineSuffix() throws {
        let path = try makeFile("keyed.swift")
        XCTAssertEqual(classify(.path(path + ":12"))?.key, classify(.path(path))?.key)
    }

    // Fix round 1, Finding A: an empty token resolves against cwd to cwd
    // itself, which exists, so without a guard this returned the project
    // root as a folder artifact. Reachable via TranscriptArtifactExtractor
    // reading an empty "file_path" straight off tool_use JSON, not just
    // via text scanning (which already excludes empty tokens upstream).
    func testEmptyPathIsDropped() {
        XCTAssertNil(classify(.path("")))
    }

    // Fix round 1, Finding B: URL.host does not include the port, so two
    // local servers on different ports collided on one dedup key and the
    // store silently kept only one.
    func testUrlsDifferingOnlyByPortHaveDifferentKeys() {
        XCTAssertNotEqual(classify(.url("http://localhost:3000/"))?.key,
                          classify(.url("http://localhost:8080/"))?.key)
    }

    // A URL with no explicit port must still key exactly as before the
    // port fix, so testUrlDedupKeyNormalisesHostCaseAndTrailingSlash keeps
    // passing unchanged.
    func testUrlWithNoExplicitPortKeysAsBefore() {
        XCTAssertEqual(classify(.url("https://a.dev/x"))?.key, "https://a.dev/x")
    }
}
