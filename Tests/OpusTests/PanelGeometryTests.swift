import XCTest
@testable import Opus

final class PanelGeometryTests: XCTestCase {
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 949)

    func testOversizedSavedGeometryIsClamped() {
        let r = PanelGeometryDefaults.clamped(saved: (width: 3000, height: 2000), toVisible: screen)
        XCTAssertEqual(r.width, 1512)
        XCTAssertEqual(r.height, 949)
    }
    func testNilSavedFallsBackToDefaults() {
        let r = PanelGeometryDefaults.clamped(saved: nil, toVisible: screen)
        XCTAssertEqual(r.width, 1512)                    // full width
        XCTAssertEqual(r.height, 949 * 0.4, accuracy: 0.5) // 40% height
    }
    func testReasonableSavedGeometryPassesThrough() {
        let r = PanelGeometryDefaults.clamped(saved: (width: 1000, height: 500), toVisible: screen)
        XCTAssertEqual(r.width, 1000)
        XCTAssertEqual(r.height, 500)
    }
}
