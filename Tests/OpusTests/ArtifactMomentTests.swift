import XCTest
@testable import OpusArtifactsKit

/// The drawer's time groups: fixed slices a person can predict, newest first.
final class ArtifactMomentTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Paris")!
        c.locale = Locale(identifier: "fr_FR")
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private var now: Date { date(30, 14) }

    private func artifact(_ name: String, _ kind: ArtifactKind = .file, at timestamp: Date?) -> Artifact {
        Artifact(key: "/r/\(name)", kind: kind, resolvedPath: "/r/\(name)", urlString: nil, timestamp: timestamp)
    }

    func testFiftyNineMinutesAgoIsTheLastHour() {
        XCTAssertEqual(ArtifactMoment.of(now.addingTimeInterval(-59 * 60), now: now, calendar: calendar), .lastHour)
    }

    func testAFutureTimestampCountsAsTheLastHour() {
        XCTAssertEqual(ArtifactMoment.of(now.addingTimeInterval(30), now: now, calendar: calendar), .lastHour)
    }

    func testEarlierTodayIsToday() {
        XCTAssertEqual(ArtifactMoment.of(date(30, 8), now: now, calendar: calendar), .today)
    }

    func testYesterdayIsYesterday() {
        XCTAssertEqual(ArtifactMoment.of(date(29, 23, 30), now: now, calendar: calendar), .yesterday)
    }

    func testOlderIsItsDay() {
        XCTAssertEqual(ArtifactMoment.of(date(27, 10), now: now, calendar: calendar),
                       .day(calendar.startOfDay(for: date(27, 10))))
    }

    func testNoTimestampIsUndated() {
        XCTAssertEqual(ArtifactMoment.of(nil, now: now, calendar: calendar), .undated)
    }

    func testTitles() {
        XCTAssertEqual(ArtifactMoment.lastHour.title(calendar: calendar), "Dernière heure")
        XCTAssertEqual(ArtifactMoment.today.title(calendar: calendar), "Aujourd'hui")
        XCTAssertEqual(ArtifactMoment.yesterday.title(calendar: calendar), "Hier")
        XCTAssertEqual(ArtifactMoment.day(calendar.startOfDay(for: date(27, 10))).title(calendar: calendar),
                       "mardi 27 octobre")
        XCTAssertEqual(ArtifactMoment.undated.title(calendar: calendar), "Plus tôt")
    }

    func testSectionsAreNewestFirstWithUndatedLast() {
        let sections = ArtifactSections.build([
            artifact("old.md", at: nil),
            artifact("y.md", at: date(29, 9)),
            artifact("recent.md", at: now.addingTimeInterval(-600)),
            artifact("week.md", at: date(26, 9)),
        ], now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.moment), [
            .lastHour, .yesterday, .day(calendar.startOfDay(for: date(26, 9))), .undated,
        ])
    }

    func testImagesAndOthersAreSplitInsideASectionNewestFirst() {
        let sections = ArtifactSections.build([
            artifact("b.md", at: now.addingTimeInterval(-1200)),
            artifact("a.png", .image, at: now.addingTimeInterval(-600)),
            artifact("e.pdf", at: now.addingTimeInterval(-300)),
            artifact("z.png", .image, at: now.addingTimeInterval(-900)),
        ], now: now, calendar: calendar)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].images.map(\.displayName), ["a.png", "z.png"])
        XCTAssertEqual(sections[0].others.map(\.displayName), ["e.pdf", "b.md"])
    }
}
