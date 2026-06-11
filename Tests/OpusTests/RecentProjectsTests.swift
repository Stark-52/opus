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
        let initial = (1...OpusPreferences.recentProjectsLimit).map { "/p\($0)" }
        let r = OpusPreferences.updatedRecentProjects(initial, adding: "/new")
        XCTAssertEqual(r.count, OpusPreferences.recentProjectsLimit)
        XCTAssertEqual(r.first, "/new")
        XCTAssertFalse(r.contains("/p\(OpusPreferences.recentProjectsLimit)"))
    }

    func testNormalizesTrailingSlash() {
        let r = OpusPreferences.updatedRecentProjects(["/a/b"], adding: "/a/b/")
        XCTAssertEqual(r, ["/a/b"])
    }

    func testIgnoresEmptyPath() {
        let r = OpusPreferences.updatedRecentProjects(["/a"], adding: "   ")
        XCTAssertEqual(r, ["/a"])
    }
}
