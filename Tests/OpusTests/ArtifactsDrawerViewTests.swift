import XCTest
@testable import Opus
@testable import OpusArtifactsKit

/// Only the pure formatter is unit-tested. Layout, thumbnails and gestures
/// are verified on screen in Task 11, because static review of this file
/// has twice missed z-order and anchoring bugs that a screenshot caught.
final class ArtifactsDrawerViewTests: XCTestCase {

    private func file(_ n: Int) -> Artifact {
        Artifact(key: "/tmp/\(n)", kind: .file, resolvedPath: "/tmp/\(n)", urlString: nil)
    }

    func testHeaderCountsArtifacts() {
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: []), "Artifacts 0")
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: [file(1), file(2)]), "Artifacts 2")
    }
}
