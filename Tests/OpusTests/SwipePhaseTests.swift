import XCTest
import AppKit
@testable import Opus
@testable import OpusArtifactsKit

/// How a scroll event's phases become a swipe phase: momentum first, then
/// the gesture's own phase; a wheel (no phase) is not a swipe.
final class SwipePhaseTests: XCTestCase {
    func testMomentumWinsOverTheGesturePhase() {
        XCTAssertEqual(TerminalContainerView.swipePhase(phase: [], momentumPhase: .changed), .momentum)
    }

    func testTheGesturePhasesMap() {
        XCTAssertEqual(TerminalContainerView.swipePhase(phase: .began, momentumPhase: []), .began)
        XCTAssertEqual(TerminalContainerView.swipePhase(phase: .changed, momentumPhase: []), .changed)
        XCTAssertEqual(TerminalContainerView.swipePhase(phase: .ended, momentumPhase: []), .ended)
        XCTAssertEqual(TerminalContainerView.swipePhase(phase: .cancelled, momentumPhase: []), .cancelled)
    }

    func testAWheelAndMayBeginAreNotSwipes() {
        XCTAssertNil(TerminalContainerView.swipePhase(phase: [], momentumPhase: []))
        XCTAssertNil(TerminalContainerView.swipePhase(phase: .mayBegin, momentumPhase: []))
    }
}
