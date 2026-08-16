import XCTest
@testable import OpusArtifactsKit

/// Pure lens over an already-built list. No disk, no AppKit. The view owns
/// which chip is selected; this owns what that selection means.
final class ArtifactKindFilterTests: XCTestCase {

    private func make(_ kind: ArtifactKind, _ name: String) -> Artifact {
        kind == .url
            ? Artifact(key: "https://\(name)", kind: .url, resolvedPath: nil, urlString: "https://\(name)")
            : Artifact(key: "/tmp/\(name)", kind: kind, resolvedPath: "/tmp/\(name)", urlString: nil)
    }

    private lazy var sample: [Artifact] = [
        make(.file, "a.md"), make(.image, "b.png"), make(.url, "c.dev"),
        make(.folder, "d"), make(.file, "e.txt")
    ]

    func testAllKeepsEverythingInOrder() {
        XCTAssertEqual(ArtifactKindFilter.apply(.all, to: sample), sample)
    }

    func testFilesExcludesImages() {
        // Two chips whose counts overlapped would not add up to the total,
        // which is the whole reason .file and .image are separate kinds.
        let out = ArtifactKindFilter.apply(.files, to: sample)
        XCTAssertEqual(out.map(\.displayName), ["a.md", "e.txt"])
    }

    func testImagesKeepsOnlyImages() {
        XCTAssertEqual(ArtifactKindFilter.apply(.images, to: sample).map(\.displayName), ["b.png"])
    }

    func testLinksKeepsOnlyUrls() {
        XCTAssertEqual(ArtifactKindFilter.apply(.links, to: sample).map(\.displayName), ["c.dev"])
    }

    func testFoldersKeepsOnlyFolders() {
        XCTAssertEqual(ArtifactKindFilter.apply(.folders, to: sample).map(\.displayName), ["d"])
    }

    func testEveryChipPartitionsTheListExactlyOnce() {
        // Files plus Images plus Links plus Folders must reconstruct All,
        // with nothing counted twice and nothing missing. This is the
        // invariant that makes the chips trustworthy.
        let parts = [ArtifactKindFilter.files, .images, .links, .folders]
            .flatMap { ArtifactKindFilter.apply($0, to: sample) }
        XCTAssertEqual(parts.count, sample.count)
        XCTAssertEqual(Set(parts.map(\.key)), Set(sample.map(\.key)))
    }

    func testOrderIsPreservedWithinAChip() {
        let out = ArtifactKindFilter.apply(.files, to: sample)
        XCTAssertEqual(out, [sample[0], sample[4]])
    }

    func testEmptyInputGivesEmptyOutputForEveryChip() {
        for chip in ArtifactKindFilter.allCases {
            XCTAssertTrue(ArtifactKindFilter.apply(chip, to: []).isEmpty)
        }
    }

    func testTitlesAreStableAndEnglish() {
        XCTAssertEqual(ArtifactKindFilter.allCases.map(\.title),
                       ["All", "Files", "Images", "Links", "Folders"])
    }
}
