import XCTest
@testable import Opus

final class PreferencesDefaultsTests: XCTestCase {
    func testNotifyOnBellDefaultsTrue() {
        UserDefaults.standard.removeObject(forKey: "opus.notifyOnBell")
        XCTAssertTrue(OpusPreferences.shared.notifyOnBell)
    }

    func testPanelPinnedDefaultsFalse() {
        UserDefaults.standard.removeObject(forKey: "opus.panelPinned")
        XCTAssertFalse(OpusPreferences.shared.panelPinned)
    }

    func testScrollbackDefaultAndClamp() {
        UserDefaults.standard.removeObject(forKey: "opus.scrollbackLines")
        XCTAssertEqual(OpusPreferences.shared.scrollbackLines, 10_000)
        OpusPreferences.shared.scrollbackLines = 500
        XCTAssertEqual(OpusPreferences.shared.scrollbackLines, 1_000)
        OpusPreferences.shared.scrollbackLines = 1_000_000
        XCTAssertEqual(OpusPreferences.shared.scrollbackLines, 200_000)
        OpusPreferences.shared.scrollbackLines = 10_000   // restore
    }

    func testEditorCommandDefault() {
        UserDefaults.standard.removeObject(forKey: "opus.editorCommand")
        XCTAssertEqual(OpusPreferences.shared.editorCommand, "code -g {target}")
        OpusPreferences.shared.editorCommand = "subl {target}"
        XCTAssertEqual(OpusPreferences.shared.editorCommand, "subl {target}")
        OpusPreferences.shared.editorCommand = "code -g {target}"   // restore
    }

    func testBumpFontSizeClampsAtBounds() {
        OpusPreferences.shared.fontSize = 24
        OpusPreferences.shared.bumpFontSize(+1)
        XCTAssertEqual(OpusPreferences.shared.fontSize, 24)
        OpusPreferences.shared.resetFontSize()
        XCTAssertEqual(OpusPreferences.shared.fontSize, 14)
    }
}
