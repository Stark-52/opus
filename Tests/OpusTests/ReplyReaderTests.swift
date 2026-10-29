// ReplyReaderTests — which text the reply drawer shows.
//
// The drawer shows Claude's answer, not its running commentary: the text it
// wrote after the last tool result of the latest turn. A turn that has not
// written anything yet leaves the previous answer on screen.

import XCTest
@testable import Opus

final class ReplyReaderTests: XCTestCase {
    private func record(_ json: String) -> String { json.replacingOccurrences(of: "\n", with: " ") }

    private func prompt(_ text: String) -> String {
        record(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":"\#(text)"}}"#)
    }

    private func said(_ text: String, sidechain: Bool = false) -> String {
        record(#"{"type":"assistant","isSidechain":\#(sidechain),"message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#)
    }

    private func toolUse() -> String {
        record(#"{"type":"assistant","isSidechain":false,"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#)
    }

    private func toolResult() -> String {
        record(#"{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#)
    }

    private func reply(_ lines: [String]) -> String? {
        ReplyReader.lastReply(fromTranscriptTail: Data(lines.joined(separator: "\n").utf8))
    }

    func testTheReplyIsWhatCameAfterTheLastToolResult() {
        let lines = [prompt("go"), said("Je regarde."), toolUse(), toolResult(), said("## Fait"), said("Tout passe.")]

        XCTAssertEqual(reply(lines), "## Fait\n\nTout passe.")
    }

    func testATurnWithoutToolsIsTheWholeReply() {
        XCTAssertEqual(reply([prompt("salut"), said("Bonjour.")]), "Bonjour.")
    }

    func testANewTurnWithNothingWrittenYetKeepsThePreviousReply() {
        let lines = [prompt("un"), said("Première réponse."), prompt("deux"), toolUse()]

        XCTAssertEqual(reply(lines), "Première réponse.")
    }

    func testCommentaryFollowedByAToolCallIsNotTheReply() {
        let lines = [prompt("un"), said("Réponse un."), prompt("deux"), said("Je regarde le code."), toolUse()]

        XCTAssertEqual(reply(lines), "Réponse un.")
    }

    func testASubagentsTextIsNotTheReply() {
        let lines = [prompt("go"), said("Réponse."), said("Texte d'un agent", sidechain: true)]

        XCTAssertEqual(reply(lines), "Réponse.")
    }

    func testAReplyBeyondTheFirstTailIsFoundByReadingFurtherBack() {
        let filler = (0..<40).flatMap { _ in [toolUse(), toolResult()] }
        let transcript = Data(([prompt("un"), said("La réponse."), prompt("deux")] + filler).joined(separator: "\n").utf8)
        var budgets: [Int] = []

        let found = ReplyReader.lastReply(startBudget: 1_024, maxBudget: 1 << 20) { budget in
            budgets.append(budget)
            return transcript.suffix(budget)
        }

        XCTAssertEqual(found, "La réponse.")
        XCTAssertGreaterThan(budgets.count, 1)
    }

    func testACutFirstLineAndAnEmptyTailAreHandled() {
        XCTAssertEqual(reply(["tent\":\"cut\"}}", prompt("go"), said("Ok.")]), "Ok.")
        XCTAssertNil(reply([]))
    }
}
