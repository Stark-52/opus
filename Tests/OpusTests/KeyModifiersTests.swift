import XCTest
import AppKit
@testable import Opus

final class KeyModifiersTests: XCTestCase {
    func testCapsLockIsStripped() {
        let flags: NSEvent.ModifierFlags = [.command, .capsLock]
        XCTAssertEqual(KeyMods.shortcutMods(flags), .command)
    }
    func testCommandShiftSurvivesWithCapsLock() {
        let flags: NSEvent.ModifierFlags = [.command, .shift, .capsLock]
        XCTAssertEqual(KeyMods.shortcutMods(flags), [.command, .shift])
    }
    func testNumericPadAndFunctionAreStripped() {
        let flags: NSEvent.ModifierFlags = [.command, .numericPad, .function]
        XCTAssertEqual(KeyMods.shortcutMods(flags), .command)
    }
    func testPlainCommandUnchanged() {
        XCTAssertEqual(KeyMods.shortcutMods([.command]), .command)
    }
    func testDeviceDependentBitsDropped() {
        // Raw device-dependent bits (e.g. left/right cmd distinction) must go.
        let raw = NSEvent.ModifierFlags(rawValue:
            NSEvent.ModifierFlags.command.rawValue | 0x0008 /* NX_DEVICELCMDKEYMASK */)
        XCTAssertEqual(KeyMods.shortcutMods(raw), .command)
    }
}
