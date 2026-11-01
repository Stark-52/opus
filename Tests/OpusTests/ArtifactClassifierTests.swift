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

    // MARK: Existing-but-not-an-artifact (final whole-branch review)

    // 346 occurrences in one real 52 MB session, from `2>/dev/null` inside
    // Bash commands. /dev/null exists, so only an explicit rule removes it.
    func testDevNullIsDropped() {
        XCTAssertNil(classify(.path("/dev/null")))
    }

    func testDevConsoleIsDropped() {
        XCTAssertNil(classify(.path("/dev/console")))
    }

    // Positive control for the rule above: the test is a prefix on the
    // RESOLVED path, not a substring on the token, so an ordinary file whose
    // name merely contains "dev" survives.
    func testFileNamedDevIsNotDropped() throws {
        let path = try makeFile("dev-notes.md")
        XCTAssertEqual(classify(.path(path))?.resolvedPath, path)
    }

    func testFolderNamedDevIsNotDropped() throws {
        let path = try makeDir("dev")
        XCTAssertEqual(classify(.path(path))?.kind, .folder)
    }

    // "///" in assistant prose used to reach here as a path and resolve to
    // "/", which exists. TextArtifactScanner now rejects it upstream; this
    // closes the tool_use route, which has no scanner in front of it.
    func testFilesystemRootIsDropped() {
        XCTAssertNil(classify(.path("/")))
    }

    // The project root is mentioned constantly and is never a product. It
    // also cannot be a folder Claude just made: cwd existed before the
    // session did.
    func testCwdItselfIsDropped() {
        XCTAssertNil(classify(.path(root.path)))
    }

    func testDotResolvingToCwdIsDropped() {
        XCTAssertNil(classify(.path(".")))
    }

    // Measured on the real transcripts: an ellipsis in prose resolves to
    // <cwd>/... , which does not exist, and firstExisting's trailing-dot
    // retry then yields <cwd>/ , which does — a second project-root row
    // under a second dedup key. The scanner now rejects "..." upstream;
    // this covers the tool_use route, which has no scanner in front of it.
    func testCwdWithTrailingSlashIsDropped() {
        XCTAssertNil(classify(.path("...")))
    }

    func testHomeDirectoryIsDropped() {
        XCTAssertNil(classify(.path(NSHomeDirectory()), cwd: "/"))
    }

    // The cwd rule must not swallow the things inside cwd, which are
    // exactly what the drawer exists to show.
    func testFileInsideCwdIsKept() throws {
        let path = try makeFile("inside.md")
        XCTAssertEqual(classify(.path(path))?.resolvedPath, path)
    }

    // MARK: What a shell command names

    // Commands name folders to move around in (`cd`, `ls`, `S=…`) far more
    // often than they name a product: measured on a real session, 92 folder
    // rows came from commands alone and none was a deliverable.
    func testAFolderAShellCommandNamedIsDropped() throws {
        let path = try makeDir("rendus")
        XCTAssertNil(ArtifactClassifier.classify(ArtifactCandidate(payload: .path(path), cwd: root.path,
                                                                   filesOnly: true)))
    }

    func testAFileAShellCommandNamedIsKept() throws {
        let path = try makeFile("planche.jpg")
        let artifact = ArtifactClassifier.classify(ArtifactCandidate(payload: .path(path), cwd: root.path,
                                                                     filesOnly: true))
        XCTAssertEqual(artifact?.kind, .image)
    }

    // MARK: Places that hold no product, whoever names them

    func testHiddenFilesAndFoldersAreDropped() throws {
        let config = try makeDir(".config/tool")
        let dotfile = try makeFile(".gitignore")
        let inside = root.appendingPathComponent(".config/tool/settings.md")
        try Data("x".utf8).write(to: inside)
        XCTAssertNil(classify(.path(config)))
        XCTAssertNil(classify(.path(dotfile)))
        XCTAssertNil(classify(.path(inside.path)))
    }

    func testTheInsideOfAnAppBundleIsDropped() throws {
        _ = try makeDir("Outil.app/Contents/MacOS")
        let binary = root.appendingPathComponent("Outil.app/Contents/MacOS/Outil")
        try Data("x".utf8).write(to: binary)
        XCTAssertNil(classify(.path(binary.path)))
    }

    func testSystemFoldersAreDropped() {
        XCTAssertNil(classify(.path("/bin/zsh")))
        XCTAssertNil(classify(.path("/usr/bin/env")))
    }

    func testTheLibraryUnderHomeIsDroppedExceptCloudDrives() {
        let home = "/Users/someone"
        XCTAssertTrue(ArtifactClassifier.isNoise("/Users/someone/Library/Caches/browsers/shell", cwd: "/", home: home))
        XCTAssertTrue(ArtifactClassifier.isNoise("/Users/someone/Library/Android/sdk/platform-tools/adb", cwd: "/", home: home))
        XCTAssertFalse(ArtifactClassifier.isNoise("/Users/someone/Library/Mobile Documents/com~apple~CloudDocs/devis.pdf",
                                                  cwd: "/", home: home))
        XCTAssertFalse(ArtifactClassifier.isNoise("/Users/someone/Library/CloudStorage/Drive/devis.pdf", cwd: "/", home: home))
    }

    // Claude Code's own temporary folder holds background task logs next to
    // the scratchpad; only what was made in the scratchpad is a product.
    func testClaudeTemporaryFilesAreDroppedOutsideTheScratchpad() {
        let session = "/private/tmp/claude-501/-Users-someone-proj/abc123"
        let home = "/Users/someone"
        XCTAssertTrue(ArtifactClassifier.isNoise("\(session)/tasks/b1x.output", cwd: "/", home: home))
        XCTAssertTrue(ArtifactClassifier.isNoise("\(session)/scratchpad", cwd: "/", home: home))
        XCTAssertFalse(ArtifactClassifier.isNoise("\(session)/scratchpad/facture/brouillon.pdf", cwd: "/", home: home))
        XCTAssertFalse(ArtifactClassifier.isNoise("/tmp/claude-501/-Users-someone-proj/abc123/scratchpad/a.png",
                                                  cwd: "/", home: home))
    }
}
