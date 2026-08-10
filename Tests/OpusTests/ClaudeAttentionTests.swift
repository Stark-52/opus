import XCTest
@testable import Opus

final class ClaudeAttentionTests: XCTestCase {
    override func tearDown() {
        // ClaudeAttention.shared is a singleton — restore its injectable
        // hooks so other tests (and other runs of these tests) don't
        // observe leftover overrides.
        ClaudeAttention.shared.isUserLookingAtOpus = { NSApp.isActive }
        ClaudeAttention.shared.postSystemSignals = { _ in }
        UserDefaults.standard.removeObject(forKey: "opus.notifyOnBell")
        super.tearDown()
    }

    func testBellSuppressedWhenUserIsLooking() {
        UserDefaults.standard.set(true, forKey: "opus.notifyOnBell")
        let attention = ClaudeAttention.shared
        attention.postSystemSignals = { _ in XCTFail("system signal must not fire while the user is looking at Opus") }
        attention.isUserLookingAtOpus = { true }

        let before = attention.lastSignalAt
        attention.bellReceived(title: "ignored")

        XCTAssertEqual(attention.lastSignalAt, before)
    }

    func testBellDebounced() {
        UserDefaults.standard.set(true, forKey: "opus.notifyOnBell")
        let attention = ClaudeAttention.shared
        attention.isUserLookingAtOpus = { false }
        var signalCount = 0
        attention.postSystemSignals = { _ in signalCount += 1 }

        attention.bellReceived(title: "first")
        let firstSignal = attention.lastSignalAt
        XCTAssertNotNil(firstSignal)
        XCTAssertEqual(signalCount, 1)

        // A second bell arriving immediately after (well inside the 3s
        // debounce window) must not fire another signal.
        attention.bellReceived(title: "second")

        XCTAssertEqual(signalCount, 1)
        XCTAssertEqual(attention.lastSignalAt, firstSignal)
    }
}
