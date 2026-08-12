import XCTest
@testable import Opus

/// FINDING (a), v1.6 backlog task-1 fix round: `TerminalContainerView.
/// deliver(bytes:)` writes raw UTF-8 straight to the PTY, so every `\n`
/// inside a multi-line paste (or palette insert, or Cmd+Ctrl+S send) looks
/// exactly like the user pressing Return between lines — claude submits at
/// the first newline instead of receiving the whole block. Exercises the
/// extracted pure wrapper (`bracketedPaste(_:enabled:)`) directly — no live
/// TerminalView/PTY needed.
final class BracketedPasteTests: XCTestCase {
    private let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC [ 2 0 0 ~
    private let end: [UInt8]   = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~

    func testEnabledWrapsWithTheExactByteSequences() {
        let bytes = TerminalContainerView.bracketedPaste("hi", enabled: true)
        XCTAssertEqual(bytes, start + Array("hi".utf8) + end)
    }

    func testEnabledWrapsMultiLineTextIntactWithEmbeddedNewlines() {
        let text = "line one\nline two\nline three"
        let bytes = TerminalContainerView.bracketedPaste(text, enabled: true)
        XCTAssertEqual(bytes, start + Array(text.utf8) + end)
    }

    func testDisabledReturnsThePlainUTF8BytesUnwrapped() {
        // The exact behavior `deliver(bytes:)` always had — a target that
        // never asked for bracketed paste (CSI ?2004h) must not see the
        // markers, or they'd land as literal garbage characters instead of
        // being interpreted as paste boundaries.
        let text = "line one\nline two"
        XCTAssertEqual(TerminalContainerView.bracketedPaste(text, enabled: false), Array(text.utf8))
    }

    func testEmptyStringEnabled() {
        XCTAssertEqual(TerminalContainerView.bracketedPaste("", enabled: true), start + end)
    }

    func testEmptyStringDisabled() {
        XCTAssertEqual(TerminalContainerView.bracketedPaste("", enabled: false), [])
    }

    func testBareEscByteIsNotSanitized() {
        // Only the exact 6-byte ESC[201~ terminator is special-cased (see
        // the function's doc comment for why). A lone/unpaired ESC, or any
        // OTHER escape sequence, inside pasted text is left exactly as is —
        // matching how real terminals don't otherwise sanitize paste
        // content.
        let text = "before\u{1B}[31mred\u{1B}[0mafter"   // ESC[31m / ESC[0m — SGR color codes, not the paste terminator
        let bytes = TerminalContainerView.bracketedPaste(text, enabled: true)
        XCTAssertEqual(bytes, start + Array(text.utf8) + end)
    }

    func testEmbeddedEndMarkerIsStrippedWhenEnabled() {
        // A literal ESC[201~ inside the payload is indistinguishable, on
        // the wire, from our own closing marker — any bracketed-paste-aware
        // reader (claude's TUI included) would end the paste right there
        // and treat everything after (including the REAL closing marker and
        // whatever follows) as live, unwrapped keystrokes. We strip exactly
        // this one sequence before wrapping so that can't happen.
        let text = "before\u{1B}[201~after"
        let bytes = TerminalContainerView.bracketedPaste(text, enabled: true)
        XCTAssertEqual(bytes, start + Array("beforeafter".utf8) + end)
    }

    func testEmbeddedEndMarkerIsNotStrippedWhenDisabled() {
        // No wrapper is being added when disabled, so there's no boundary
        // for an embedded end marker to break — pass the bytes through
        // completely unchanged, same as any other byte in the disabled
        // path.
        let text = "before\u{1B}[201~after"
        XCTAssertEqual(TerminalContainerView.bracketedPaste(text, enabled: false), Array(text.utf8))
    }
}
