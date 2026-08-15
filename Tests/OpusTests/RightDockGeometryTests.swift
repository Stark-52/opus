import XCTest
@testable import OpusArtifactsKit

/// The arithmetic that the v1.6 button-row bug lived in. It is pulled out
/// into pure functions precisely so a second drawer cannot reintroduce it
/// by copying the numbers into a second place.
final class RightDockGeometryTests: XCTestCase {

    func testClosedDockTakesNoWidth() {
        XCTAssertEqual(RightDockGeometry.width(for: .none), 0)
        XCTAssertEqual(RightDockGeometry.terminalTrailingConstant(for: .none), 0)
        XCTAssertFalse(RightDockGeometry.isOpen(.none))
    }

    func testTasksKeepsItsHistoricalWidth() {
        // Changing this silently would move a drawer users already know.
        XCTAssertEqual(RightDockGeometry.width(for: .tasks), 260)
        XCTAssertEqual(RightDockGeometry.terminalTrailingConstant(for: .tasks), -260)
    }

    func testArtifactsIsWiderToFitAThumbnail() {
        XCTAssertEqual(RightDockGeometry.width(for: .artifacts), 300)
        XCTAssertEqual(RightDockGeometry.terminalTrailingConstant(for: .artifacts), -300)
    }

    func testEitherOccupantCountsAsOpen() {
        XCTAssertTrue(RightDockGeometry.isOpen(.tasks))
        XCTAssertTrue(RightDockGeometry.isOpen(.artifacts))
    }
}
