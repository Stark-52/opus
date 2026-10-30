import XCTest
@testable import OpusArtifactsKit

/// The arithmetic that the v1.6 button-row bug lived in. It is pulled out
/// into pure functions precisely so a second drawer cannot reintroduce it
/// by copying the numbers into a second place.
final class DrawerGeometryTests: XCTestCase {

    func testClosedDockTakesNoWidth() {
        XCTAssertEqual(DrawerGeometry.width(for: .none), 0)
        XCTAssertEqual(DrawerGeometry.edgeConstant(for: .none), 0)
        XCTAssertFalse(DrawerGeometry.isOpen(.none))
    }

    func testTasksKeepsItsHistoricalWidth() {
        // Changing this silently would move a drawer users already know.
        XCTAssertEqual(DrawerGeometry.width(for: .reply), 380)
        XCTAssertEqual(DrawerGeometry.edgeConstant(for: .reply), -380)
    }

    func testArtifactsIsWiderToFitAThumbnail() {
        XCTAssertEqual(DrawerGeometry.width(for: .artifacts), 300)
        XCTAssertEqual(DrawerGeometry.edgeConstant(for: .artifacts), -300)
    }

    func testEitherOccupantCountsAsOpen() {
        XCTAssertTrue(DrawerGeometry.isOpen(.reply))
        XCTAssertTrue(DrawerGeometry.isOpen(.artifacts))
    }

    func testSides() {
        XCTAssertEqual(DrawerGeometry.side(for: .reply), .leading)
        XCTAssertEqual(DrawerGeometry.side(for: .artifacts), .trailing)
    }

    func testOffsets() {
        XCTAssertEqual(DrawerGeometry.offset(width: 300, side: .leading, progress: 0.25), -225)
        XCTAssertEqual(DrawerGeometry.offset(width: 300, side: .trailing, progress: 0), 300)
        XCTAssertEqual(DrawerGeometry.offset(width: 300, side: .trailing, progress: 1), 0)
        XCTAssertEqual(DrawerGeometry.offset(width: 300, side: .leading, progress: 1.4), 0, "clamped")
    }
}
