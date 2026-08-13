import XCTest
@testable import OpusSecretsKit

final class PutInputResolverTests: XCTestCase {
    func testPipedNonEmptyStdinIsUsedVerbatimAfterTrim() {
        let outcome = PutInputResolver.resolve(
            isTTY: false,
            readStdin: { "  re_live_abc123  \n" },
            readClipboard: { XCTFail("clipboard must not be read when input is piped"); return "" }
        )
        XCTAssertEqual(outcome, .value("re_live_abc123", source: .stdin))
    }

    func testPipedEmptyStdinIsEmptyStdin() {
        let outcome = PutInputResolver.resolve(
            isTTY: false,
            readStdin: { "   \n\n  " },
            readClipboard: { XCTFail("clipboard must not be read when input is piped"); return "" }
        )
        XCTAssertEqual(outcome, .emptyStdin)
    }

    func testInteractiveTerminalReadsClipboardInstead() {
        let outcome = PutInputResolver.resolve(
            isTTY: true,
            readStdin: { XCTFail("stdin must not be read on an interactive terminal"); return "" },
            readClipboard: { "  sk_live_xyz  " }
        )
        XCTAssertEqual(outcome, .value("sk_live_xyz", source: .clipboard))
    }

    func testInteractiveTerminalWithEmptyClipboardIsEmptyClipboard() {
        let outcome = PutInputResolver.resolve(
            isTTY: true,
            readStdin: { XCTFail("stdin must not be read on an interactive terminal"); return "" },
            readClipboard: { "" }
        )
        XCTAssertEqual(outcome, .emptyClipboard)
    }

    func testInteractiveTerminalWithWhitespaceOnlyClipboardIsEmptyClipboard() {
        let outcome = PutInputResolver.resolve(
            isTTY: true,
            readStdin: { XCTFail("stdin must not be read on an interactive terminal"); return "" },
            readClipboard: { "   \n  " }
        )
        XCTAssertEqual(outcome, .emptyClipboard)
    }

    func testOnlyOneReaderIsInvokedPerCall() {
        var stdinCalls = 0
        var clipboardCalls = 0

        _ = PutInputResolver.resolve(
            isTTY: false,
            readStdin: { stdinCalls += 1; return "value" },
            readClipboard: { clipboardCalls += 1; return "value" }
        )
        XCTAssertEqual(stdinCalls, 1)
        XCTAssertEqual(clipboardCalls, 0)

        _ = PutInputResolver.resolve(
            isTTY: true,
            readStdin: { stdinCalls += 1; return "value" },
            readClipboard: { clipboardCalls += 1; return "value" }
        )
        XCTAssertEqual(stdinCalls, 1)
        XCTAssertEqual(clipboardCalls, 1)
    }
}
