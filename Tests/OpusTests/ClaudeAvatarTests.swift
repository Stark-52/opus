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

final class ClaudeAvatarHatTests: XCTestCase {
    private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = month; parts.day = day; parts.hour = hour
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    func testCalendarHats() {
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(12, 20, 14), asleep: false, calendar: cal), .santa)
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(12, 20, 23), asleep: true, calendar: cal), .santa)
        XCTAssertNil(ClaudeAvatar.seasonalHat(date(12, 10, 14), asleep: false, calendar: cal))
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(11, 10, 23), asleep: true, calendar: cal), .nightcap)
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(11, 10, 3), asleep: true, calendar: cal), .nightcap)
        XCTAssertNil(ClaudeAvatar.seasonalHat(date(11, 10, 23), asleep: false, calendar: cal))
        XCTAssertNil(ClaudeAvatar.seasonalHat(date(11, 10, 15), asleep: true, calendar: cal))
    }

    func testPartiesWearAPartyHatAndSleepersSleep() {
        XCTAssertEqual(ClaudeAvatar.celebrating(elapsed: 0.5)?.hat, .party)
        XCTAssertTrue(ClaudeAvatar.sleeping(time: 1).asleep)
        XCTAssertTrue(ClaudeAvatar.lookingAround(time: 1).magnifier)
    }
}

/// Draws each pose into a bitmap and counts the pixels it covered: a
/// structural slip in `draw` (once, the whole avatar ended up inside the
/// confetti loop and only showed during a celebration) compiles and passes
/// every pose test, so only ink on the page catches it.
final class ClaudeAvatarInkTests: XCTestCase {
    private func ink(_ pose: ClaudeAvatar.Pose, size: Int = 32) -> Int {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        ClaudeAvatar.draw(pose, color: OpusTheme.cyan, in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var count = 0
        for x in 0..<size { for y in 0..<size where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 } }
        return count
    }

    func testEveryStateDrawsAnAvatar() {
        let poses: [ClaudeAvatar.Pose?] = [
            ClaudeAvatar.pose(.working, time: 0.3), ClaudeAvatar.pose(.needsInput, time: 0.3),
            ClaudeAvatar.pose(.done, time: 0), ClaudeAvatar.sleeping(time: 1), ClaudeAvatar.lookingAround(time: 1),
            ClaudeAvatar.Pose(eyes: .tired), ClaudeAvatar.celebrating(elapsed: 0.5),
        ]
        for pose in poses {
            // The body alone is a disc of radius 0.29: about a quarter of the square.
            XCTAssertGreaterThan(ink(pose!), 32 * 32 / 5, "\(pose!)")
        }
    }
}

final class ClaudeAvatarPNGTests: XCTestCase {
    func testWaitingThumbnailIsAPNG() {
        let data = ClaudeAvatar.pngData(ClaudeAvatar.pose(.needsInput, time: 0.3)!, color: OpusTheme.red, size: 256)
        XCTAssertNotNil(data)
        XCTAssertEqual(Array(data!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertNotNil(NSImage(data: data!))
    }
}

final class MenuBarCountTests: XCTestCase {
    func testCountShowsFromTwoWaiting() {
        XCTAssertEqual(MenuBarAvatar.badge(0), "")
        XCTAssertEqual(MenuBarAvatar.badge(1), "")
        XCTAssertEqual(MenuBarAvatar.badge(3), "3")
        XCTAssertEqual(MenuBarAvatar.toolTip(.needsInput, waiting: 2), "2 sessions t'attendent")
        XCTAssertEqual(MenuBarAvatar.toolTip(.needsInput, waiting: 1), "Claude attend ta réponse")
    }
}

final class ClaudeAvatarWeekTests: XCTestCase {
    func testSpentWeekSleeps() {
        let pose = ClaudeAvatar.tired(ClaudeAvatar.pose(.needsInput, time: 1)!, weekPercent: 100)
        XCTAssertEqual(pose.eyes, .closed)
        XCTAssertTrue(pose.asleep)
        XCTAssertFalse(pose.asks)
        XCTAssertEqual(MenuBarAvatar.toolTip(.idle, weekPercent: 100), "Claude se repose\nsemaine 100\u{00A0}%, limite atteinte")
    }

    func testFreshWeekIsNoticed() {
        XCTAssertTrue(ClaudeAvatar.weekReset(from: 99, to: 2))
        XCTAssertFalse(ClaudeAvatar.weekReset(from: 60, to: 2))
        XCTAssertFalse(ClaudeAvatar.weekReset(from: 99, to: 98))
        XCTAssertFalse(ClaudeAvatar.weekReset(from: nil, to: 2))
    }
}

final class ClaudeAvatarGettingUpTests: XCTestCase {
    func testStretchesYawnsAndOpensItsEyes() {
        XCTAssertEqual(ClaudeAvatar.gettingUp(elapsed: 0.1)?.eyes, .closed)
        XCTAssertEqual(ClaudeAvatar.gettingUp(elapsed: 0.4)?.eyes, .open)
        XCTAssertGreaterThan(ClaudeAvatar.gettingUp(elapsed: 0.2)!.yawn, 0.8)
        XCTAssertLessThan(ClaudeAvatar.gettingUp(elapsed: 0.3)!.squash, -0.1)
        XCTAssertNil(ClaudeAvatar.gettingUp(elapsed: ClaudeAvatar.gettingUpLength))
        let squashes = stride(from: 0.0, to: ClaudeAvatar.gettingUpLength, by: 0.01).compactMap { ClaudeAvatar.gettingUp(elapsed: $0)?.squash }
        XCTAssertGreaterThanOrEqual(squashes.min()!, -0.12)
    }
}

final class ClaudeAvatarMomentTests: XCTestCase {
    func testEachChangeHasItsScene() {
        XCTAssertEqual(ClaudeAvatar.transition(from: .working, to: .done), .celebrate)
        XCTAssertEqual(ClaudeAvatar.transition(from: .idle, to: .working), .getUp)
        XCTAssertEqual(ClaudeAvatar.transition(from: .done, to: .working), .getUp)
        XCTAssertEqual(ClaudeAvatar.transition(from: .needsInput, to: .working), .nod)
        XCTAssertEqual(ClaudeAvatar.transition(from: .working, to: .needsInput), .startle)
        XCTAssertNil(ClaudeAvatar.transition(from: .done, to: .idle))
    }

    func testEveryMomentStaysInsideItsSquareAndEnds() {
        let all: [ClaudeAvatar.Moment] = [.celebrate, .getUp, .nod, .startle, .wink, .jump, .dizzy, .sneeze]
        for kind in all {
            let length = ClaudeAvatar.length(kind)
            let poses = stride(from: 0.0, to: length, by: 0.01).compactMap { ClaudeAvatar.moment(kind, elapsed: $0) }
            XCTAssertFalse(poses.isEmpty, "\(kind)")
            XCTAssertLessThanOrEqual(poses.map(\.hop).max()!, 0.12, "\(kind)")
            XCTAssertLessThanOrEqual(poses.map { abs($0.squash) }.max()!, 0.12, "\(kind)")
            XCTAssertNil(ClaudeAvatar.moment(kind, elapsed: length), "\(kind)")
        }
    }

    func testBoopsWinkAndDizzyLook() {
        XCTAssertTrue(ClaudeAvatar.moment(.wink, elapsed: 0.3)!.wink)
        XCTAssertEqual(ClaudeAvatar.moment(.dizzy, elapsed: 0.5)?.eyes, .dizzy)
        XCTAssertNotNil(ClaudeAvatar.moment(.dizzy, elapsed: 0.5)?.stars)
        XCTAssertEqual(ClaudeAvatar.dozing(time: 3).eyes, .closed)
    }
}

final class ClaudeAvatarDecorTests: XCTestCase {
    private let cal = Calendar(identifier: .gregorian)
    private func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day; parts.hour = hour
        return cal.date(from: parts)!
    }

    func testHolidayHats() {
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(10, 31, 12), asleep: false, calendar: cal), .witch)
        XCTAssertNil(ClaudeAvatar.seasonalHat(date(10, 20, 12), asleep: false, calendar: cal))
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(12, 31, 12), asleep: false, calendar: cal), .party)
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(1, 1, 12), asleep: false, calendar: cal), .party)
        XCTAssertEqual(ClaudeAvatar.seasonalHat(date(12, 30, 12), asleep: false, calendar: cal), .santa)
    }

    func testWeekendAndCoffeeHours() {
        XCTAssertTrue(ClaudeAvatar.weekend(date(11, 14, 12), calendar: cal))    // a Saturday
        XCTAssertTrue(ClaudeAvatar.weekend(date(11, 15, 12), calendar: cal))    // a Sunday
        XCTAssertFalse(ClaudeAvatar.weekend(date(11, 11, 12), calendar: cal))   // a Wednesday
        XCTAssertTrue(ClaudeAvatar.coffeeHours(date(11, 11, 3), calendar: cal))
        XCTAssertFalse(ClaudeAvatar.coffeeHours(date(11, 11, 6), calendar: cal))
    }

    func testEveryTenthFinishGetsHearts() {
        XCTAssertFalse(MenuBarAvatar.hearts(afterFinishing: 9))
        XCTAssertTrue(MenuBarAvatar.hearts(afterFinishing: 10))
        XCTAssertTrue(MenuBarAvatar.hearts(afterFinishing: 20))
        XCTAssertEqual(MenuBarAvatar.toolTip(.done, finished: 3), "Claude a fini\n3 tâches finies aujourd'hui")
    }
}

final class TabAccessibilityTests: XCTestCase {
    func testEachTabSaysWhatClaudeDoes() {
        let strip = ChromeTabStrip(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        strip.titles = ["Avatar", "Prospection", ""]
        strip.states = [.working, .idle, .needsInput]
        let children = strip.accessibilityChildren() as? [TabAccessibilityElement]
        XCTAssertEqual(children?.count, 3)
        XCTAssertEqual(children?[0].accessibilityLabel(), "Avatar, Claude travaille depuis moins d'une minute")
        XCTAssertEqual(children?[1].accessibilityLabel(), "Prospection")
        XCTAssertEqual(children?[2].accessibilityLabel(), "Claude, Claude t'attend depuis moins d'une minute")
        XCTAssertEqual(children?[0].accessibilityValue() as? Int, 1)
        XCTAssertEqual(children?[1].accessibilityValue() as? Int, 0)
        XCTAssertEqual(strip.accessibilityRole(), .tabGroup)
    }
}

final class TabAccessibilityStabilityTests: XCTestCase {
    func testElementsStayTheSameUntilTabsChange() {
        let strip = ChromeTabStrip(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        strip.titles = ["A", "B"]
        strip.states = [.working, .idle]
        let first = strip.accessibilityChildren() as? [TabAccessibilityElement]
        let again = strip.accessibilityChildren() as? [TabAccessibilityElement]
        XCTAssertTrue(first![0] === again![0])
        strip.titles = ["A", "B", "C"]
        XCTAssertEqual((strip.accessibilityChildren() as? [TabAccessibilityElement])?.count, 3)
    }
}

final class ClaudeAvatarPonderTests: XCTestCase {
    func testPonderingLooksUp() {
        XCTAssertGreaterThan(ClaudeAvatar.pondering(time: 1).lift, 0)
        XCTAssertFalse(ClaudeAvatar.pondering(time: 1).magnifier)
    }
}
