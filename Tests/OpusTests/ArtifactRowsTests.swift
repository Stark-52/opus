import XCTest
@testable import OpusArtifactsKit

/// The drawer's rows: a header per moment, its images three to a strip,
/// then its other artifacts one per row.
final class ArtifactRowsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func artifact(_ name: String, _ kind: ArtifactKind, minutesAgo: Double) -> Artifact {
        Artifact(key: "/r/\(name)", kind: kind, resolvedPath: "/r/\(name)", urlString: nil,
                 timestamp: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testEachSectionIsAHeaderThenImageStripsThenItems() {
        let i1 = artifact("1.png", .image, minutesAgo: 1)
        let i2 = artifact("2.png", .image, minutesAgo: 2)
        let i3 = artifact("3.png", .image, minutesAgo: 3)
        let i4 = artifact("4.png", .image, minutesAgo: 4)
        let pdf = artifact("devis.pdf", .file, minutesAgo: 5)
        let sections = ArtifactSections.build([pdf, i3, i1, i4, i2], now: now, calendar: calendar)

        XCTAssertEqual(ArtifactRows.make(sections, calendar: calendar), [
            .header("Dernière heure"), .images([i1, i2, i3]), .images([i4]), .item(pdf),
        ])
    }

    func testASectionWithoutImagesHasNoStrip() {
        let md = artifact("notes.md", .file, minutesAgo: 1)
        let sections = ArtifactSections.build([md], now: now, calendar: calendar)
        XCTAssertEqual(ArtifactRows.make(sections, calendar: calendar), [.header("Dernière heure"), .item(md)])
    }

    func testDisplayOrderWalksImagesThenItemsSectionBySection() {
        let i1 = artifact("1.png", .image, minutesAgo: 1)
        let md = artifact("notes.md", .file, minutesAgo: 2)
        let rows = ArtifactRows.make(ArtifactSections.build([md, i1], now: now, calendar: calendar), calendar: calendar)
        XCTAssertEqual(ArtifactRows.displayOrder(rows), [i1, md])
    }
}
