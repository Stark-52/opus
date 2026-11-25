import XCTest
@testable import OpusBridgeKit

/// The bridge's messages cross a socket as one JSON line each, and a
/// delegated turn is over at the right event, not at an earlier one.
final class BridgeKitTests: XCTestCase {
    func testARequestIsOneLineAndComesBackIntact() {
        let request = BridgeRequest(op: .ask, task: "ligne 1\nligne \"2\" et l'apostrophe", codeMode: true)
        let line = BridgeWire.line(request)
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "a task's newlines are escaped, never raw")
        XCTAssertEqual(BridgeWire.decode(BridgeRequest.self, from: line.dropLast()), request)
    }

    func testAMessageComesBackIntact() {
        let message = BridgeMessage(kind: .done, session: "s1", reply: "Réponse\nsur deux lignes")
        XCTAssertEqual(BridgeWire.decode(BridgeMessage.self, from: BridgeWire.line(message).dropLast()), message)
    }

    func testMissingFlagsTakeTheirDefaults() {
        let request = BridgeWire.decode(BridgeRequest.self, from: Data(#"{"op":"ask","task":"x"}"#.utf8))
        XCTAssertEqual(request, BridgeRequest(op: .ask, task: "x", codeMode: true, wait: false))
    }

    func testOnlyAcceptedLeavesTheExchangeOpen() {
        XCTAssertFalse(BridgeMessage(kind: .accepted).isFinal)
        for kind in [BridgeMessage.Kind.done, .needsInput, .working, .error] {
            XCTAssertTrue(BridgeMessage(kind: kind).isFinal, "\(kind)")
        }
    }

    func testANewTabIsDoneAtItsFirstTurnEnd() {
        var watch = TurnWatch(awaitingPrompt: false)
        XCTAssertNil(watch.observe(.other))
        XCTAssertEqual(watch.observe(.turnEnded), .done)
    }

    func testAFollowUpIgnoresTheEndOfAnEarlierTurn() {
        var watch = TurnWatch(awaitingPrompt: true)
        XCTAssertNil(watch.observe(.turnEnded))
        XCTAssertNil(watch.observe(.promptSubmitted))
        XCTAssertEqual(watch.observe(.turnEnded), .done)
    }

    func testAPermissionPromptStopsTheWait() {
        var watch = TurnWatch(awaitingPrompt: false)
        XCTAssertEqual(watch.observe(.attention(kind: "permission_prompt", message: "Claude needs your permission to use Bash")),
                       .needsInput(message: "Claude needs your permission to use Bash"))
    }

    func testAnIdlePromptDoesNotStopIt() {
        var watch = TurnWatch(awaitingPrompt: false)
        XCTAssertNil(watch.observe(.attention(kind: "idle_prompt", message: "Claude is waiting for your input")))
        XCTAssertNil(watch.observe(.attention(kind: "auth_success", message: "")))
    }
}
