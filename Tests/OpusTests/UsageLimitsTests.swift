// UsageLimitsTests — the plan's 5-hour and 7-day windows on the status rail.
//
// The figures come from Claude Code's status line input (`rate_limits`),
// which the status line command copies to Application Support/Opus/
// usage.json on every refresh; Opus only reads that file. A window whose
// reset time has passed is hidden: its figure belongs to a window that no
// longer exists, and the next API response brings the new one.

import XCTest
@testable import Opus

final class UsageLimitsTests: XCTestCase {

    /// 2026-10-29 21:00 in Paris.
    private let now = Date(timeIntervalSince1970: 1_793_304_000)

    private func file(_ json: String) -> Data { Data(json.utf8) }

    func testParsesBothWindowsInRailOrder() {
        let windows = UsageLimits.parse(file("""
        {"seven_day":{"used_percentage":83,"resets_at":1793600000},
         "five_hour":{"used_percentage":42.4,"resets_at":1793310000}}
        """))

        XCTAssertEqual(windows.map(\.kind), [.fiveHour, .sevenDay])
        XCTAssertEqual(windows.first?.percent, 42.4)
        XCTAssertEqual(windows.first?.resetsAt, Date(timeIntervalSince1970: 1_793_310_000))
    }

    func testAMissingOrMalformedFileHasNoWindows() {
        XCTAssertEqual(UsageLimits.parse(file("")), [])
        XCTAssertEqual(UsageLimits.parse(file("{\"five_hour\":{\"resets_at\":1}}")), [])
        XCTAssertEqual(UsageLimits.parse(file("[1,2]")), [])
    }

    func testAWindowPastItsResetIsDropped() {
        let windows = UsageLimits.parse(file("""
        {"five_hour":{"used_percentage":97,"resets_at":1793300000},
         "seven_day":{"used_percentage":40,"resets_at":1793600000}}
        """))

        XCTAssertEqual(UsageLimits.current(windows, now: now).map(\.kind), [.sevenDay])
    }

    func testUsageEscalatesAtHalfAndAtEightyPercent() {
        XCTAssertEqual(UsageLimits.level(percent: 49.9), .nominal)
        XCTAssertEqual(UsageLimits.level(percent: 50), .attention)
        XCTAssertEqual(UsageLimits.level(percent: 80), .critical)
    }
}
