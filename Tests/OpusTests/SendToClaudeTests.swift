import XCTest
@testable import Opus

/// v1.6 backlog Task 2 — Cmd+Ctrl+S "Send to Claude". Only `composeSendPayload`
/// is pure/testable without a live AppDelegate + Carbon event loop; the
/// hotkey registration, clipboard read, and panel-reveal side effects are
/// exercised manually (see task-2-report.md).
final class SendToClaudeTests: XCTestCase {
    func testTemplateSubstitution() {
        XCTAssertEqual(AppDelegate.composeSendPayload(template: "{clipboard}", clipboard: "abc"), "abc")
        XCTAssertEqual(AppDelegate.composeSendPayload(template: "Explique ceci:\n{clipboard}", clipboard: "x"), "Explique ceci:\nx")
    }

    func testTemplateWithoutPlaceholderAppendsTheClipboard() {
        // A template that forgets {clipboard} must not silently drop it.
        XCTAssertEqual(AppDelegate.composeSendPayload(template: "Contexte:", clipboard: "x"), "Contexte:\nx")
    }

    func testEmptyClipboardYieldsEmptyPayload() {
        XCTAssertEqual(AppDelegate.composeSendPayload(template: "{clipboard}", clipboard: ""), "")
    }

    func testEmptyTemplateSendsTheClipboardBareWithNoLeadingBlankLine() {
        // Fix round finding F9: an empty template (no {clipboard} placeholder
        // to match, so it used to fall into the "append on its own line"
        // branch) used to prefix the clipboard with a stray "\n" — "\nx"
        // instead of "x". An empty template has nothing to prepend.
        XCTAssertEqual(AppDelegate.composeSendPayload(template: "", clipboard: "x"), "x")
    }
}
