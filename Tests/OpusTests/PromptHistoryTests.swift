import XCTest
@testable import Opus

final class PromptHistoryTests: XCTestCase {
    private func line(_ s: String) -> Data { Data(s.utf8) }

    func testParsesAPlainPrompt() {
        let e = PromptHistory.parse(line: line(#"{"display":"refactor le parser","pastedContents":{},"timestamp":1772230832330,"project":"/Users/x/proj","sessionId":"abc"}"#))
        XCTAssertEqual(e?.text, "refactor le parser")
        XCTAssertEqual(e?.project, "/Users/x/proj")
        // Brief's literal `XCTAssertEqual(e?.timestamp.timeIntervalSince1970,
        // 1772230832.330, accuracy: 0.01)` does not compile — XCTest's
        // `accuracy:` overload requires non-optional FloatingPoint on both
        // sides, and optional chaining makes the left side `Double?`. `?? 0`
        // keeps the same pass/fail behavior (0 fails the accuracy check just
        // as loudly as a literal nil would) while typechecking.
        XCTAssertEqual(e?.timestamp.timeIntervalSince1970 ?? 0, 1772230832.330, accuracy: 0.01)
    }

    func testPastedPlaceholderIsReplacedByTheRealContent() {
        // `display` is only a placeholder when the user pasted; the real text
        // lives in pastedContents. The palette must insert what was pasted.
        let raw = #"{"display":"[Pasted text #1 +19 lines]","pastedContents":{"1":{"id":1,"type":"text","content":"ligne A\nligne B"}},"timestamp":1,"project":"/p","sessionId":"s"}"#
        XCTAssertEqual(PromptHistory.parse(line: line(raw))?.text, "ligne A\nligne B")
    }

    func testEmptyDisplayIsRejected() {
        XCTAssertNil(PromptHistory.parse(line: line(#"{"display":"","pastedContents":{},"timestamp":1,"project":"/p","sessionId":"s"}"#)))
    }

    func testMalformedLineIsNil() {
        XCTAssertNil(PromptHistory.parse(line: line("{not json")))
    }

    func testMissingProjectFallsBackToEmptyString() {
        let e = PromptHistory.parse(line: line(#"{"display":"x","timestamp":1,"sessionId":"s"}"#))
        XCTAssertEqual(e?.project, "")
        XCTAssertEqual(e?.text, "x")
    }
}
