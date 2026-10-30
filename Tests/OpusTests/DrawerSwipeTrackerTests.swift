import XCTest
@testable import OpusArtifactsKit

/// A two-finger swipe over the terminal: right pulls Copy in from the left,
/// left pulls Artifacts in from the right, the reverse closes, and anything
/// that is not clearly horizontal belongs to the terminal's scrolling.
final class DrawerSwipeTrackerTests: XCTestCase {
    private var tracker = DrawerSwipeTracker()
    private let width: CGFloat = 300

    @discardableResult
    private func feed(_ phase: DrawerSwipeTracker.Phase, _ dx: CGFloat, _ dy: CGFloat = 0,
                      at time: TimeInterval, open: DrawerGeometry.Occupant = .none) -> DrawerSwipeTracker.Output {
        tracker.feed(phase: phase, fingerDX: dx, dy: dy, time: time, open: open, width: { [width] _ in width })
    }

    func testAClearlyHorizontalSwipeRightOpensCopyAndFollowsTheFingers() {
        XCTAssertEqual(feed(.began, 0, at: 0), .passThrough)
        XCTAssertEqual(feed(.changed, 30, at: 0.02), .progress(.reply, 0.1))
    }

    func testASwipeLeftOpensArtifacts() {
        feed(.began, 0, at: 0)
        XCTAssertEqual(feed(.changed, -60, at: 0.02), .progress(.artifacts, 0.2))
    }

    func testADiagonalScrollStaysVertical() {
        feed(.began, 0, at: 0)
        XCTAssertEqual(feed(.changed, 10, 8, at: 0.02), .passThrough)
        XCTAssertEqual(feed(.changed, 0, 40, at: 0.04), .passThrough)
        XCTAssertEqual(feed(.changed, 40, 0, at: 0.06), .passThrough, "the axis is decided once per gesture")
        XCTAssertEqual(feed(.ended, 0, at: 0.08), .passThrough)
    }

    func testReleasingPastAThirdOpens() {
        feed(.began, 0, at: 0)
        for step in 1...11 { feed(.changed, 10, at: Double(step) * 0.1) }
        XCTAssertEqual(feed(.ended, 0, at: 1.2), .finish(.reply, open: true))
    }

    func testReleasingShortOfAThirdWithoutAFlingCloses() {
        feed(.began, 0, at: 0)
        feed(.changed, 20, at: 0.1)
        feed(.changed, 20, at: 0.6)
        XCTAssertEqual(feed(.ended, 0, at: 0.7), .finish(.reply, open: false))
    }

    func testAFastFlingOpensEvenWhenShort() {
        feed(.began, 0, at: 0)
        feed(.changed, 20, at: 0.025)
        feed(.changed, 20, at: 0.05)
        XCTAssertEqual(feed(.ended, 0, at: 0.06), .finish(.reply, open: true))
    }

    func testTheReverseSwipeClosesTheOpenDrawer() {
        feed(.began, 0, at: 0, open: .artifacts)
        XCTAssertEqual(feed(.changed, 150, at: 0.3, open: .artifacts), .progress(.artifacts, 0.5))
        XCTAssertEqual(feed(.ended, 0, at: 0.4, open: .artifacts), .finish(.artifacts, open: false))
    }

    func testTheWrongWayOverAnOpenDrawerPassesThrough() {
        feed(.began, 0, at: 0, open: .artifacts)
        XCTAssertEqual(feed(.changed, -30, at: 0.02, open: .artifacts), .passThrough)
        XCTAssertEqual(feed(.ended, 0, at: 0.04, open: .artifacts), .passThrough)
    }

    func testMomentumAfterAHorizontalSwipeIsConsumedAndChangesNothing() {
        feed(.began, 0, at: 0)
        feed(.changed, 120, at: 0.2)
        feed(.ended, 0, at: 0.3)
        XCTAssertEqual(feed(.momentum, 30, at: 0.32), .consume)
        XCTAssertEqual(feed(.momentum, 10, at: 0.34), .consume)
    }

    func testMomentumAfterAVerticalScrollPassesThrough() {
        feed(.began, 0, at: 0)
        feed(.changed, 0, 30, at: 0.02)
        feed(.ended, 0, at: 0.04)
        XCTAssertEqual(feed(.momentum, 0, 20, at: 0.06), .passThrough)
    }

    func testCancelledRestoresTheStartingState() {
        feed(.began, 0, at: 0, open: .artifacts)
        feed(.changed, 200, at: 0.2, open: .artifacts)
        XCTAssertEqual(feed(.cancelled, 0, at: 0.3, open: .artifacts), .finish(.artifacts, open: true))
    }

    func testFingerDirectionFollowsNaturalScrolling() {
        XCTAssertEqual(DrawerSwipeTracker.fingerDX(scrollingDeltaX: 5, invertedFromDevice: true), 5)
        XCTAssertEqual(DrawerSwipeTracker.fingerDX(scrollingDeltaX: 5, invertedFromDevice: false), -5)
    }

    func testHoldingBeforeLettingGoIsNotAFling() {
        feed(.began, 0, at: 0)
        feed(.changed, 20, at: 0.025)
        feed(.changed, 20, at: 0.05)
        XCTAssertEqual(feed(.ended, 0, at: 1.05), .finish(.reply, open: false))
    }
}
