import XCTest
@testable import OpusArtifactsKit

/// What counts as code: source and configuration files a session touches by
/// the dozen and nobody opens from the drawer.
final class ArtifactCodeTests: XCTestCase {
    private func file(_ path: String) -> Artifact {
        Artifact(key: path, kind: .file, resolvedPath: path, urlString: nil)
    }

    func testSourceAndConfigFilesAreCode() {
        for ext in ["swift", "ts", "tsx", "json", "yml", "lock", "SWIFT"] {
            XCTAssertTrue(ArtifactCode.isCode(file("/r/a.\(ext)")), ext)
        }
    }

    func testDocumentsImagesAndFoldersAreNotCode() {
        for ext in ["md", "pdf", "html", "txt", "csv"] {
            XCTAssertFalse(ArtifactCode.isCode(file("/r/a.\(ext)")), ext)
        }
        XCTAssertFalse(ArtifactCode.isCode(Artifact(key: "i", kind: .image, resolvedPath: "/r/a.png", urlString: nil)))
        XCTAssertFalse(ArtifactCode.isCode(Artifact(key: "d", kind: .folder, resolvedPath: "/r/x.swift", urlString: nil)))
        XCTAssertFalse(ArtifactCode.isCode(file("/r/Makefile")))
    }
}
