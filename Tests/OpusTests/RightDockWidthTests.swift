import XCTest
@testable import OpusArtifactsKit

/// Width stopped being a constant when the drawer became resizable. The
/// defaults are still the numbers users already know; everything else here
/// exists so a dragged edge cannot produce a drawer that is unusable or one
/// that swallows the terminal.
final class RightDockWidthTests: XCTestCase {

    func testDefaultsAreTheWidthsUsersAlreadyKnow() {
        XCTAssertEqual(RightDockGeometry.defaultWidth(for: .tasks), 260)
        XCTAssertEqual(RightDockGeometry.defaultWidth(for: .artifacts), 300)
        XCTAssertEqual(RightDockGeometry.defaultWidth(for: .none), 0)
    }

    func testClampRefusesToGoBelowUsable() {
        XCTAssertEqual(RightDockGeometry.clampWidth(10, for: .artifacts),
                       RightDockGeometry.minimumWidth)
        XCTAssertEqual(RightDockGeometry.clampWidth(-500, for: .tasks),
                       RightDockGeometry.minimumWidth)
    }

    func testClampRefusesToSwallowTheTerminal() {
        XCTAssertEqual(RightDockGeometry.clampWidth(9000, for: .artifacts),
                       RightDockGeometry.maximumWidth)
    }

    func testClampPassesSensibleWidthsThrough() {
        XCTAssertEqual(RightDockGeometry.clampWidth(340, for: .artifacts), 340)
        XCTAssertEqual(RightDockGeometry.clampWidth(260, for: .tasks), 260)
    }

    func testBothDefaultsSurviveTheirOwnClamp() {
        // A default outside its own bounds would mean a drawer that jumps the
        // first time it is dragged, which is the kind of thing nobody notices
        // until a user does.
        for occupant in [RightDockGeometry.Occupant.tasks, .artifacts] {
            let d = RightDockGeometry.defaultWidth(for: occupant)
            XCTAssertEqual(RightDockGeometry.clampWidth(d, for: occupant), d)
        }
    }

    func testClosedDockHasNoWidthWhateverIsProposed() {
        // `.none` is not a drawer, so it cannot be resized into one.
        XCTAssertEqual(RightDockGeometry.clampWidth(400, for: .none), 0)
        XCTAssertEqual(RightDockGeometry.clampWidth(0, for: .none), 0)
    }

    func testMinimumIsBelowMaximumAndBothArePositive() {
        XCTAssertLessThan(RightDockGeometry.minimumWidth, RightDockGeometry.maximumWidth)
        XCTAssertGreaterThan(RightDockGeometry.minimumWidth, 0)
    }

    func testTerminalTrailingConstantIsTheNegatedResolvedWidth() {
        XCTAssertEqual(RightDockGeometry.terminalTrailingConstant(forWidth: 300), -300)
        XCTAssertEqual(RightDockGeometry.terminalTrailingConstant(forWidth: 0), 0)
    }
}
