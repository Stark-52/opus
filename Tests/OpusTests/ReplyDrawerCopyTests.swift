// ReplyDrawerCopyTests: what each copy button of the reply drawer puts on
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

    func testProseCopiesFormattedWithThePlainTextAlongside() throws {
        let drawer = ReplyDrawerView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        drawer.reply = "## Titre\nUn **mot**.\n\n```\nlet x = 1\n```"
        let all = buttons(in: drawer)

        XCTAssertEqual(copied(by: all[0]), "Titre\n\nUn mot.\n\nlet x = 1", "plain text for places that take only text")
        let html = try XCTUnwrap(board.string(forType: .html))
        XCTAssertTrue(html.hasSuffix("<h2>Titre</h2><p>Un <strong>mot</strong>.</p><pre><code>let x = 1</code></pre>"), html)

        // Mail, Notes and Pages read the RTF: bold where the reply is bold,
        // and no colour, so the drawer's cream never lands on a white page.
        let rtf = try XCTUnwrap(board.data(forType: .rtf))
        let rich = try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
        let word = (rich.string as NSString).range(of: "mot")
        let font = try XCTUnwrap(rich.attribute(.font, at: word.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        let body = try XCTUnwrap(rich.attribute(.font, at: word.location - 3, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(body.familyName, "Helvetica Neue",
                       "the system font as RTF writes it, not the Times an unstyled HTML reads as")
        XCTAssertEqual(body.pointSize, 13)
        XCTAssertEqual(font.familyName, body.familyName)
        var colored: [String] = []
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if value != nil { colored.append((rich.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(colored, [])

        XCTAssertEqual(copied(by: all[2]), "Un mot.")
        XCTAssertEqual(board.string(forType: .html).map { $0.hasSuffix("<p>Un <strong>mot</strong>.</p>") }, true)
    }

    func testACodeBlockCopiesAsTheCodeAlone() {
        let drawer = ReplyDrawerView(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        drawer.reply = "```\nlet x = 1\n```"

        XCTAssertEqual(copied(by: buttons(in: drawer)[1]), "let x = 1")
        let types = board.types ?? []
        XCTAssertFalse(types.contains(.html) || types.contains(.rtf),
                       "an editor or a terminal pastes the code, never a formatted copy of it")
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
