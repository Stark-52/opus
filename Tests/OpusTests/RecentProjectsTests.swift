import XCTest
@testable import Opus

final class RecentProjectsTests: XCTestCase {
    func testInsertsAtFront() {
        let r = OpusPreferences.updatedRecentProjects(["/a", "/b"], adding: "/c")
        XCTAssertEqual(r, ["/c", "/a", "/b"])
    }

    func testDeduplicatesExisting() {
        let r = OpusPreferences.updatedRecentProjects(["/a", "/b", "/c"], adding: "/b")
        XCTAssertEqual(r, ["/b", "/a", "/c"])
    }

    func testCapsAtEight() {
        let initial = (1...8).map { "/p\($0)" }
        let r = OpusPreferences.updatedRecentProjects(initial, adding: "/new")
        XCTAssertEqual(r.count, 8)
        XCTAssertEqual(r.first, "/new")
        XCTAssertFalse(r.contains("/p8"))
    }

    func testIgnoresEmptyPath() {
        let r = OpusPreferences.updatedRecentProjects(["/a"], adding: "   ")
        XCTAssertEqual(r, ["/a"])
    }
}
