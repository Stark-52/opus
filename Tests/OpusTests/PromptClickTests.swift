// PromptClickTests — turning a click in Claude Code's input into arrow keys.
//
// The terminal has no notion of a text cursor to click into: the input box
// is drawn by Claude Code between two `────` rules, its text starting after
// "❯ ". A click inside it becomes the arrow keys that walk the cursor there.

import XCTest
import AppKit
import SwiftTerm
@testable import Opus

final class PromptClickTests: XCTestCase {
    private func row(_ text: String) -> [PromptClick.Cell] {
        text.flatMap { character -> [PromptClick.Cell] in
            let wide = character.unicodeScalars.first.map { $0.properties.isEmojiPresentation } ?? false
            return wide ? [.init(character: character, width: 2), .init(character: " ", width: 0)]
                        : [.init(character: character, width: 1)]
        }
    }

    private lazy var screen: [[PromptClick.Cell]] = [
        row("● Une réponse au-dessus"),
        row("──────────────────────────────"),
        row("❯ corrige le bug du scroll"),
        row("  et ajoute un test 🙂 ici"),
        row("──────────────────────────────"),
        row("  ctx 31% · 5h 7%"),
    ]

    func testTheInputIsTheRowsBetweenTheTwoRules() {
        XCTAssertEqual(PromptClick.inputRows(screen, cursorRow: 2), 2...3)
        XCTAssertNil(PromptClick.inputRows(screen, cursorRow: 0), "the cursor is not in the input")
    }

    func testAClickOnTheCursorsRowMovesLeftOrRightByCharacters() {
        // Cursor after "corrige" (column 9), click on the "b" of "bug" (column 13).
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 13, row: 2)), .horizontal(4))
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 13, y: 2), click: (col: 2, row: 2)), .horizontal(-11))
    }

    func testAClickPastTheEndOfTheTextStopsAtTheEnd() {
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 2, y: 2), click: (col: 29, row: 2)), .horizontal(24))
    }

    func testAClickOnThePromptGlyphGoesToTheStartOfTheText() {
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 0, row: 2)), .horizontal(-7))
    }

    func testAWideCharacterCountsAsOneKeyPress() {
        // "  et ajoute un test 🙂 ici": the emoji takes columns 20 and 21.
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 19, y: 3), click: (col: 23, row: 3)), .horizontal(3))
    }

    func testAClickOnAnotherInputRowMovesVerticallyFirst() {
        XCTAssertEqual(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 5, row: 3)), .vertical(1))
    }

    func testAClickOutsideTheInputDoesNothing() {
        XCTAssertNil(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 5, row: 0)))
        XCTAssertNil(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 5, row: 5)))
        XCTAssertNil(PromptClick.plan(screen, cursor: (x: 9, y: 2), click: (col: 9, row: 2)), "already there")
    }
}

/// The same walk read off a real SwiftTerm screen: empty cells, wide
/// characters and the cursor as the terminal reports them.
final class PromptClickTerminalTests: XCTestCase {
    private func terminal(showing lines: [String], cursorRow: Int, cursorCol: Int) -> Terminal {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        view.feed(text: lines.joined(separator: "\r\n"))
        view.feed(text: "\u{1b}[\(cursorRow + 1);\(cursorCol + 1)H")
        return view.getTerminal()
    }

    private let input = [
        "● Une réponse",
        "──────────────────────────────",
        "❯ corrige le bug du scroll",
        "  et ajoute un test 🙂 ici",
        "──────────────────────────────",
    ]

    func testAClickOnTheCursorsRowSendsRightArrows() throws {
        let term = terminal(showing: input, cursorRow: 2, cursorCol: 9)
        let step = try XCTUnwrap(PromptClick.keys(in: term, click: (col: 13, row: 2), allowVertical: true))

        XCTAssertEqual(step.keys, Array(repeating: EscapeSequences.moveRightNormal, count: 4).flatMap { $0 })
        XCTAssertFalse(step.isVertical)
    }

    func testAWideCharacterOnTheRealScreenIsOnePress() throws {
        let term = terminal(showing: input, cursorRow: 3, cursorCol: 19)
        let step = try XCTUnwrap(PromptClick.keys(in: term, click: (col: 23, row: 3), allowVertical: true))

        XCTAssertEqual(step.keys.count, 3 * EscapeSequences.moveRightNormal.count)
    }

    func testAnotherRowSendsUpOrDownOnceAndNeverTwice() throws {
        let term = terminal(showing: input, cursorRow: 3, cursorCol: 5)
        let step = try XCTUnwrap(PromptClick.keys(in: term, click: (col: 9, row: 2), allowVertical: true))

        XCTAssertEqual(step.keys, EscapeSequences.moveUpNormal)
        XCTAssertTrue(step.isVertical)
        XCTAssertNil(PromptClick.keys(in: term, click: (col: 9, row: 2), allowVertical: false))
    }

    func testOutsideTheInputNothingIsSent() {
        let term = terminal(showing: input, cursorRow: 2, cursorCol: 9)

        XCTAssertNil(PromptClick.keys(in: term, click: (col: 3, row: 0), allowVertical: true))
    }
}
