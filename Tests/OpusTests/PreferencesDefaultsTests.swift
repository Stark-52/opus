import XCTest
@testable import Opus

final class PreferencesDefaultsTests: XCTestCase {
    func testNotifyOnBellDefaultsTrue() {
        UserDefaults.standard.removeObject(forKey: "opus.notifyOnBell")
        XCTAssertTrue(OpusPreferences.shared.notifyOnBell)
    }
}
