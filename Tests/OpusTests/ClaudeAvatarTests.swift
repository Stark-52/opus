import XCTest
@testable import Opus

final class ClaudeAvatarTests: XCTestCase {
    func testIdleDrawsNothingLikeTheDotDid() {
        XCTAssertNil(ClaudeAvatar.pose(.idle, time: 1))
        XCTAssertNil(OpusTheme.activityColor(.idle))
    }

    func testOnlyWorkingAndWaitingMove() {
        XCTAssertTrue(ClaudeAvatar.isAnimated(.working, reduceMotion: false))
        XCTAssertTrue(ClaudeAvatar.isAnimated(.needsInput, reduceMotion: false))
        XCTAssertFalse(ClaudeAvatar.isAnimated(.done, reduceMotion: false))
        XCTAssertFalse(ClaudeAvatar.isAnimated(.idle, reduceMotion: false))
        XCTAssertFalse(ClaudeAvatar.isAnimated(.working, reduceMotion: true))
    }

    func testWorkingTurnsItsRays() {
        let a = ClaudeAvatar.pose(.working, time: 0.5)!
        let b = ClaudeAvatar.pose(.working, time: 1.0)!
        XCTAssertNotEqual(a.rotation, b.rotation)
        XCTAssertEqual(a.hop, 0)
    }

    func testWaitingHopsAndStaysInsideItsSquare() {
        let hops = stride(from: 0.0, to: 3.0, by: 0.01).map { ClaudeAvatar.pose(.needsInput, time: $0)!.hop }
        XCTAssertGreaterThan(hops.max()!, 0.1)
        XCTAssertGreaterThanOrEqual(hops.min()!, 0)
        // Rays reach 0.48 of the side from the center: a hop of 0.12 keeps
        // the avatar within a 24 pt tab at 16 pt.
        XCTAssertLessThanOrEqual(hops.max()!, 0.12)
    }

    func testDoneSmilesAndHoldsStill() {
        XCTAssertEqual(ClaudeAvatar.pose(.done, time: 7), ClaudeAvatar.Pose(eyes: .happy))
    }

    func testReduceMotionHoldsTheRestingPose() {
        XCTAssertEqual(ClaudeAvatar.pose(.working, time: 5, reduceMotion: true),
                       ClaudeAvatar.pose(.working, time: 0))
        XCTAssertEqual(ClaudeAvatar.pose(.needsInput, time: 0)?.eyes, .open)
    }

    func testBlinksBrieflyOncePerPeriod() {
        XCTAssertFalse(ClaudeAvatar.blinking(0, every: 3.6))
        XCTAssertFalse(ClaudeAvatar.blinking(1, every: 3.6))
        XCTAssertTrue(ClaudeAvatar.blinking(3.55, every: 3.6))
        XCTAssertFalse(ClaudeAvatar.blinking(3.65, every: 3.6))
    }
}

final class ClaudeAvatarMoodTests: XCTestCase {
    func testSleepingSnoresWithEyesShut() {
        let pose = ClaudeAvatar.sleeping(time: 1.3)
        XCTAssertEqual(pose.eyes, .closed)
        XCTAssertNotNil(pose.snore)
        XCTAssertTrue((0..<1).contains(pose.snore!))
        XCTAssertNil(ClaudeAvatar.pose(.working, time: 1)?.snore)
    }

    func testLookingAroundMovesItsEyes() {
        XCTAssertNotEqual(ClaudeAvatar.lookingAround(time: 0.5).glance,
                          ClaudeAvatar.lookingAround(time: 2).glance)
    }
}

final class ClaudeAvatarJoyTests: XCTestCase {
    func testCelebrationSmilesThenEnds() {
        XCTAssertEqual(ClaudeAvatar.celebrating(elapsed: 0.3)?.eyes, .happy)
        XCTAssertNil(ClaudeAvatar.celebrating(elapsed: ClaudeAvatar.celebrationLength))
        XCTAssertNil(ClaudeAvatar.celebrating(elapsed: -1))
    }

    func testCelebrationStaysInsideItsSquare() {
        let hops = stride(from: 0.0, to: ClaudeAvatar.celebrationLength, by: 0.01)
            .compactMap { ClaudeAvatar.celebrating(elapsed: $0)?.hop }
        XCTAssertLessThanOrEqual(hops.max()!, 0.12)
        XCTAssertGreaterThanOrEqual(hops.min()!, 0)
    }

    func testMenuBarShowsTheStrongestState() {
        XCTAssertEqual(ClaudeAvatar.strongest([.done, .working, .idle]), .working)
        XCTAssertEqual(ClaudeAvatar.strongest([.working, .needsInput]), .needsInput)
        XCTAssertEqual(ClaudeAvatar.strongest([.idle, .done]), .done)
        XCTAssertEqual(ClaudeAvatar.strongest([]), .idle)
    }
}

final class TabStateLineTests: XCTestCase {
    func testSaysWhatAndHowLong() {
        XCTAssertNil(ChromeTabStrip.stateLine(.idle, for: 600))
        XCTAssertEqual(ChromeTabStrip.stateLine(.working, for: 20), "Claude travaille depuis moins d'une minute")
        XCTAssertEqual(ChromeTabStrip.stateLine(.needsInput, for: 4 * 60 + 30), "Claude t'attend depuis 4 min")
        XCTAssertEqual(ChromeTabStrip.stateLine(.done, for: 65 * 60), "Claude a fini il y a 1 h 05")
    }
}

final class ClaudeAvatarTiredTests: XCTestCase {
    func testOpenEyesDroopPastNinetyPercent() {
        let open = ClaudeAvatar.Pose()
        XCTAssertEqual(ClaudeAvatar.tired(open, weekPercent: 99).eyes, .tired)
        XCTAssertEqual(ClaudeAvatar.tired(open, weekPercent: 89).eyes, .open)
        XCTAssertEqual(ClaudeAvatar.tired(open, weekPercent: nil).eyes, .open)
        XCTAssertEqual(ClaudeAvatar.tired(ClaudeAvatar.Pose(eyes: .happy), weekPercent: 99).eyes, .happy)
    }

    func testMenuBarTooltipCarriesTheWeek() {
        XCTAssertEqual(MenuBarAvatar.toolTip(.working), "Claude travaille")
        XCTAssertEqual(MenuBarAvatar.toolTip(.needsInput, weekPercent: 98.6), "Claude attend ta réponse\nsemaine 99\u{00A0}%")
    }
}

final class ClaudeAvatarGestureTests: XCTestCase {
    func testWaitingWavesAndAsks() {
        let waves = stride(from: 0.0, to: 2.0, by: 0.05).compactMap { ClaudeAvatar.pose(.needsInput, time: $0)?.wave }
        XCTAssertGreaterThan(waves.max()!, 0.3)
        XCTAssertLessThan(waves.min()!, -0.3)
        XCTAssertTrue(ClaudeAvatar.pose(.needsInput, time: 1)!.asks)
        XCTAssertFalse(ClaudeAvatar.pose(.working, time: 1)!.asks)
    }

    func testWorkingLooksUpToThinkNowAndThen() {
        XCTAssertEqual(ClaudeAvatar.pose(.working, time: 1)!.lift, 0)
        XCTAssertGreaterThan(ClaudeAvatar.pose(.working, time: 5)!.lift, 0)
        XCTAssertEqual(ClaudeAvatar.pose(.working, time: 5, reduceMotion: true)!.lift, 0)
    }
}

final class ClaudeAvatarYawnTests: XCTestCase {
    func testSleeperYawnsNowAndThen() {
        XCTAssertEqual(ClaudeAvatar.sleeping(time: 3).yawn, 0)
        XCTAssertGreaterThan(ClaudeAvatar.sleeping(time: 8.25).yawn, 0.9)
        XCTAssertEqual(ClaudeAvatar.pose(.working, time: 8.25)?.yawn, 0)
    }
}

final class ClaudeAvatarLateNightTests: XCTestCase {
    func testYawnsOnlyLateAndOnlyAwake() {
        let awake = ClaudeAvatar.Pose()
        XCTAssertGreaterThan(ClaudeAvatar.lateNight(awake, hour: 23, time: 11.25).yawn, 0.9)
        XCTAssertGreaterThan(ClaudeAvatar.lateNight(awake, hour: 3, time: 11.25).yawn, 0.9)
        XCTAssertEqual(ClaudeAvatar.lateNight(awake, hour: 14, time: 11.25).yawn, 0)
        XCTAssertEqual(ClaudeAvatar.lateNight(awake, hour: 23, time: 5).yawn, 0)
        XCTAssertEqual(ClaudeAvatar.lateNight(ClaudeAvatar.Pose(eyes: .happy), hour: 23, time: 11.25).yawn, 0)
    }
}

final class ClaudeAvatarCartoonTests: XCTestCase {
    func testSquashStaysGentleAndRestsAtZero() {
        let squashes = stride(from: 0.0, to: 3.0, by: 0.01).compactMap { ClaudeAvatar.pose(.needsInput, time: $0)?.squash }
        XCTAssertLessThanOrEqual(squashes.map(abs).max()!, 0.12)
        XCTAssertGreaterThan(squashes.max()!, 0.1)      // crouches
        XCTAssertLessThan(squashes.min()!, -0.03)       // stretches
        XCTAssertEqual(ClaudeAvatar.pose(.needsInput, time: 0)?.squash, 0)
    }

    func testCelebrationThrowsConfettiOnce() {
        XCTAssertEqual(ClaudeAvatar.celebrating(elapsed: 0)?.confetti, 0)
        XCTAssertEqual(Double(ClaudeAvatar.celebrating(elapsed: 0.7)!.confetti!), 0.5, accuracy: 0.01)
        XCTAssertNil(ClaudeAvatar.pose(.done, time: 1)?.confetti)
    }

    func testLateNightYawnSurvivesABlink() {
        XCTAssertGreaterThan(ClaudeAvatar.lateNight(ClaudeAvatar.Pose(eyes: .closed), hour: 23, time: 11.25).yawn, 0.9)
    }
}
