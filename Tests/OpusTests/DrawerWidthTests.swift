import XCTest
@testable import OpusArtifactsKit

/// Width stopped being a constant when the drawer became resizable. The
/// defaults are still the numbers users already know; everything else here
/// exists so a dragged edge cannot produce a drawer that is unusable or one
/// that swallows the terminal.
final class DrawerWidthTests: XCTestCase {

    func testDefaultsAreTheWidthsUsersAlreadyKnow() {
        XCTAssertEqual(DrawerGeometry.defaultWidth(for: .reply), 380)
        XCTAssertEqual(DrawerGeometry.defaultWidth(for: .artifacts), 300)
        XCTAssertEqual(DrawerGeometry.defaultWidth(for: .none), 0)
    }

    func testClampRefusesToGoBelowUsable() {
        XCTAssertEqual(DrawerGeometry.clampWidth(10, for: .artifacts),
                       DrawerGeometry.minimumWidth)
        XCTAssertEqual(DrawerGeometry.clampWidth(-500, for: .reply),
                       DrawerGeometry.minimumWidth)
    }

    func testClampRefusesToSwallowTheTerminal() {
        XCTAssertEqual(DrawerGeometry.clampWidth(9000, for: .artifacts),
                       DrawerGeometry.maximumWidth)
    }

    func testClampPassesSensibleWidthsThrough() {
        XCTAssertEqual(DrawerGeometry.clampWidth(340, for: .artifacts), 340)
        XCTAssertEqual(DrawerGeometry.clampWidth(380, for: .reply), 380)
    }

    func testBothDefaultsSurviveTheirOwnClamp() {
        // A default outside its own bounds would mean a drawer that jumps the
        // first time it is dragged, which is the kind of thing nobody notices
        // until a user does.
        for occupant in [DrawerGeometry.Occupant.reply, .artifacts] {
            let d = DrawerGeometry.defaultWidth(for: occupant)
            XCTAssertEqual(DrawerGeometry.clampWidth(d, for: occupant), d)
        }
    }

    func testClosedDockHasNoWidthWhateverIsProposed() {
        // `.none` is not a drawer, so it cannot be resized into one.
        XCTAssertEqual(DrawerGeometry.clampWidth(400, for: .none), 0)
        XCTAssertEqual(DrawerGeometry.clampWidth(0, for: .none), 0)
    }

    func testMinimumIsBelowMaximumAndBothArePositive() {
        XCTAssertLessThan(DrawerGeometry.minimumWidth, DrawerGeometry.maximumWidth)
        XCTAssertGreaterThan(DrawerGeometry.minimumWidth, 0)
    }
}
