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

    // MARK: Stepping the chips with the arrow keys

    func testStepRightWalksTheRowInOrder() {
        var chip = ArtifactKindFilter.all
        var walked: [ArtifactKindFilter] = []
        for _ in 1...5 {
            chip = ArtifactKindFilter.step(from: chip, direction: 1, keeping: sample)
            walked.append(chip)
        }
        XCTAssertEqual(walked, [.files, .images, .links, .folders, .all])
    }

    func testStepLeftWalksTheRowBackwards() {
        XCTAssertEqual(ArtifactKindFilter.step(from: .all, direction: -1, keeping: sample), .folders)
        XCTAssertEqual(ArtifactKindFilter.step(from: .files, direction: -1, keeping: sample), .all)
    }

    func testStepSkipsChipsWithNothingInThem() {
        // Files and Images only: Links and Folders have to be stepped over,
        // not landed on, or the arrow key walks into a blank list.
        let partial = [make(.file, "a.md"), make(.image, "b.png")]
        XCTAssertEqual(ArtifactKindFilter.step(from: .images, direction: 1, keeping: partial), .all)
        XCTAssertEqual(ArtifactKindFilter.step(from: .all, direction: -1, keeping: partial), .images)
    }

    func testStepStaysPutWhenNoOtherChipQualifies() {
        // One kind, so All and Files are the only non-empty chips; from
        // Files, right must reach All rather than stall.
        let onlyFiles = [make(.file, "a.md")]
        XCTAssertEqual(ArtifactKindFilter.step(from: .files, direction: 1, keeping: onlyFiles), .all)
        // Nothing at all: every chip is empty, so there is nowhere to go.
        XCTAssertEqual(ArtifactKindFilter.step(from: .files, direction: 1, keeping: []), .files)
    }

    func testStepWithADirectionOfZeroIsANoOp() {
        XCTAssertEqual(ArtifactKindFilter.step(from: .images, direction: 0, keeping: sample), .images)
    }

    func testOnlyTheSignOfTheDirectionIsRead() {
        // The callers pass +1/-1, but a stray magnitude must not skip chips.
        XCTAssertEqual(ArtifactKindFilter.step(from: .all, direction: 7, keeping: sample), .files)
        XCTAssertEqual(ArtifactKindFilter.step(from: .all, direction: -7, keeping: sample), .folders)
    }

    func testPreviewCallerNeverLandsOnLinks() {
        // The preview passes only artifacts with a file behind them, which is
        // what keeps QuickLook from being handed zero items and closing.
        let previewable = sample.filter { $0.resolvedPath != nil }
        var chip = ArtifactKindFilter.all
        for _ in 1...8 {
            chip = ArtifactKindFilter.step(from: chip, direction: 1, keeping: previewable)
            XCTAssertNotEqual(chip, .links)
        }
    }
}
