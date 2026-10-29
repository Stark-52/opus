// ReplyDrawerCopyTests — what each copy button of the reply drawer puts on
// the clipboard, clicked for real, on a pasteboard of the tests' own so a
// run never overwrites the person's clipboard.

import XCTest
import AppKit
@testable import Opus

final class ReplyDrawerCopyTests: XCTestCase {
    private let board = NSPasteboard(name: NSPasteboard.Name("opus-reply-drawer-tests"))

    override func setUp() {
        super.setUp()
        ReplyDrawerView.pasteboard = board
    }

    override func tearDown() {
        ReplyDrawerView.pasteboard = .general
        board.releaseGlobally()
        super.tearDown()
    }

    private func buttons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) }
    }

    private func copied(by button: NSButton) -> String? {
        board.clearContents()
        button.performClick(nil)
        return board.string(forType: .string)
    }

    func testEveryButtonCopiesItsOwnText() throws {
        let drawer = ReplyDrawerView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        drawer.reply = "## Titre\nUn **mot**.\n\n```\nlet x = 1\n```"
        let all = buttons(in: drawer)
        XCTAssertEqual(all.count, 4, "copy-all, then the heading, the paragraph and the code")

        XCTAssertEqual(copied(by: all[0]), "Titre\n\nUn mot.\n\nlet x = 1")
        XCTAssertEqual(copied(by: all[1]), "Titre\n\nUn mot.\n\nlet x = 1", "a heading copies its section")
        XCTAssertEqual(copied(by: all[2]), "Un mot.")
        XCTAssertEqual(copied(by: all[3]), "let x = 1")
    }

    func testANewReplyReplacesTheBlocksAndNoReplyShowsNone() {
        let drawer = ReplyDrawerView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        drawer.reply = "Un.\n\nDeux."
        drawer.reply = "Trois."
        let all = buttons(in: drawer)

        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(copied(by: all[1]), "Trois.")

        drawer.reply = nil
        XCTAssertTrue(buttons(in: drawer).dropFirst().isEmpty)
    }
}
