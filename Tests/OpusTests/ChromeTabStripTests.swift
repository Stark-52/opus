import XCTest
import AppKit
@testable import Opus

/// Tabs as wide as their title, between a floor and a ceiling, squeezed to
/// the floor when there are too many: the strip never pushes the buttons
/// out of the bar, it only cuts its own overflow.
final class ChromeTabStripTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 11.5)

    func testTabsFitTheirTitleBetween80And220() {
        let widths = ChromeTabStrip.tabWidths(titles: ["a", "Fonctionnalité des mods", String(repeating: "x", count: 80)],
                                              font: font, available: 2000)
        XCTAssertEqual(widths.count, 3)
        for width in widths { XCTAssertTrue((80...220).contains(width), "\(width)") }
        XCTAssertEqual(widths[0], 80, "a short title still gets the floor")
        XCTAssertEqual(widths[2], 220, "a long title stops at the ceiling")
    }

    func testManyTabsShrinkToTheMinimum() {
        let titles = Array(repeating: String(repeating: "Publication Instagram ", count: 3), count: 12)
        let widths = ChromeTabStrip.tabWidths(titles: titles, font: font, available: 600)
        XCTAssertEqual(widths, Array(repeating: 80, count: 12))
    }

    func testTabsThatFitKeepTheirWidth() {
        let widths = ChromeTabStrip.tabWidths(titles: ["Fonctionnalité des mods", "Publication Instagram"],
                                              font: font, available: 900)
        let natural = ChromeTabStrip.tabWidths(titles: ["Fonctionnalité des mods", "Publication Instagram"],
                                               font: font, available: 10_000)
        XCTAssertEqual(widths, natural)
    }

    func testASingleTabStillShowsItsTitle() {
        XCTAssertEqual(ChromeTabStrip.tabWidths(titles: ["Fonctionnalité des mods"], font: font, available: 600).count, 1)
    }
}
