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

    func testHeaderCountsWhatAllShowsSoCodeIsLeftOut() {
        let code = Artifact(key: "/r/main.swift", kind: .file, resolvedPath: "/r/main.swift", urlString: nil)
        XCTAssertEqual(ArtifactsDrawerView.headerText(artifacts: [file(1), code]), "Artifacts 1")
    }

    func testTheDrawerShowsRowsForTheSelectedChipOnly() {
        let now = Date()
        let code = Artifact(key: "/r/main.swift", kind: .file, resolvedPath: "/r/main.swift",
                            urlString: nil, timestamp: now)
        let image = Artifact(key: "/r/shot.png", kind: .image, resolvedPath: "/r/shot.png",
                             urlString: nil, timestamp: now)
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.update(artifacts: [code, image], hasSession: true, hasTranscript: true)

        XCTAssertFalse(drawer.displayedRows.contains(.item(code)))
        XCTAssertTrue(drawer.displayedRows.contains(.images([image])))

        drawer.select(kindFilter: .code)
        XCTAssertTrue(drawer.displayedRows.contains(.item(code)))
        XCTAssertFalse(drawer.displayedRows.contains { if case .images = $0 { return true } else { return false } })
    }

    func testClickingEmptySpaceClearsTheSelection() {
        let doc = Artifact(key: "/r/a.md", kind: .file, resolvedPath: "/r/a.md", urlString: nil, timestamp: Date())
        let drawer = ArtifactsDrawerView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
        drawer.update(artifacts: [doc], hasSession: true, hasTranscript: true)
        drawer.select(key: doc.key)
        XCTAssertEqual(drawer.selectedArtifact, doc)
        drawer.tableSelectionChanged(toRow: -1)
        XCTAssertNil(drawer.selectedArtifact)
    }

    func testTheChipRowFitsTheNarrowestDrawer() {
        XCTAssertLessThanOrEqual(ArtifactsDrawerView.chipRowWidth(),
                                 DrawerGeometry.minimumWidth - 2 * OpusTheme.insetPanel)
    }
}
