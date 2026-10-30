import XCTest
@testable import Opus

/// The status bar says what the person reads: the context as a percentage, the
/// week's usage, the five-hour one quietly, and the rest in the tooltip.
final class ChromeStatusTests: XCTestCase {
    private let resets = Date(timeIntervalSince1970: 1_900_000_000)

    func testContextIsAPercentInFrench() {
        XCTAssertEqual(ChromeStatus.context(fraction: 0.357), "contexte 36\u{00A0}%")
        XCTAssertNil(ChromeStatus.context(fraction: nil))
    }

    func testWeekAndFiveHourAreSeparateSegments() {
        let windows = [UsageWindow(kind: .fiveHour, percent: 2, resetsAt: resets),
                       UsageWindow(kind: .sevenDay, percent: 23, resetsAt: resets)]
        XCTAssertEqual(ChromeStatus.week(windows), "semaine 23\u{00A0}%")
        XCTAssertEqual(ChromeStatus.fiveHour(windows), "5h 2\u{00A0}%")
    }

    func testAnExpiredWindowShowsNothing() {
        XCTAssertNil(ChromeStatus.week([]))
        XCTAssertNil(ChromeStatus.fiveHour([]))
    }

    func testTheTooltipCarriesTokensAndResets() {
        let week = UsageWindow(kind: .sevenDay, percent: 23, resetsAt: resets)
        let tooltip = ChromeStatus.tooltip(tokens: 357_112, limit: 1_000_000, windows: [week])
        XCTAssertTrue(tooltip.contains("357k"), tooltip)
        XCTAssertTrue(tooltip.contains(UsageLimits.tooltip(week)), tooltip)
    }
}
