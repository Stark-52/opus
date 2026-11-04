// ReplyMarkdownTests — cutting a reply into the pieces the drawer copies.
//
// Each block is one copy button: a heading, a paragraph, a whole list, a
// code block, a table, a quote. Prose copies as plain text (what goes into
// a message or a post), code as the code itself, and a heading copies its
// whole section.

import XCTest
@testable import Opus

final class ReplyMarkdownTests: XCTestCase {
    private let reply = """
    ## Ce qui change

    Le **scroll** reste en place, voir `ScrollFollowTests`.

    - premier point
      sur deux lignes
    - second [lien](https://example.com)

    ```swift
    let x = 1
    ```

    | A | B |
    |---|---|
    | 1 | 2 |

    > une citation

    ---

    ### Détail
    Fin.
    """

    func testTheReplyIsCutIntoItsBlocks() {
        XCTAssertEqual(ReplyMarkdown.blocks(reply).map(\.kind), [
            .heading(level: 2), .paragraph, .list(ordered: false), .code(language: "swift"),
            .table, .quote, .rule, .heading(level: 3), .paragraph,
        ])
    }

    func testProseCopiesAsPlainText() {
        let blocks = ReplyMarkdown.blocks(reply)

        XCTAssertEqual(blocks[1].copyText, "Le scroll reste en place, voir ScrollFollowTests.")
        XCTAssertEqual(blocks[2].copyText, "- premier point\n  sur deux lignes\n- second lien (https://example.com)")
        XCTAssertEqual(blocks[5].copyText, "une citation")
    }

    /// Claude never wraps a line to fit a width: every line break it writes
    /// is meant, so the copy keeps it. A message drafted as a quote, with a
    /// numbered list and sub-points, used to paste as one run-on line.
    func testAQuotedMessageCopiesWithItsLineBreaks() {
        let blocks = ReplyMarkdown.blocks("""
        > Salut, voilà les étapes :
        >
        > 1. Ouvrir la console.
        > 2. Filmer les vidéos :
        >    • Mobile : connexion du compte.
        >    • Web : lancement du **direct**.
        >
        > Vas-y doucement.
        """)

        XCTAssertEqual(blocks.map(\.kind), [.quote])
        XCTAssertEqual(blocks[0].copyText, """
        Salut, voilà les étapes :

        1. Ouvrir la console.
        2. Filmer les vidéos :
           • Mobile : connexion du compte.
           • Web : lancement du direct.

        Vas-y doucement.
        """)
    }

    func testTheLinesOfAParagraphStayOnTheirOwnLines() {
        let blocks = ReplyMarkdown.blocks("Objet : la démo\nBonjour,\n• un point\n• un autre")

        XCTAssertEqual(blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(blocks[0].copyText, "Objet : la démo\nBonjour,\n• un point\n• un autre")
    }

    func testAListItemKeepsTheLinesWrittenUnderIt() {
        let blocks = ReplyMarkdown.blocks("1. Filmer :\n   • Mobile\n   • Web\n2. Envoyer")

        XCTAssertEqual(blocks[0].copyText, "1. Filmer :\n   • Mobile\n   • Web\n2. Envoyer")
    }

    func testCodeAndTablesCopyAsWritten() {
        let blocks = ReplyMarkdown.blocks(reply)

        XCTAssertEqual(blocks[3].copyText, "let x = 1")
        XCTAssertEqual(blocks[4].copyText, "| A | B |\n|---|---|\n| 1 | 2 |")
    }

    func testATableIsDrawnWithItsColumnsAlignedAndNoSeparatorRow() {
        let rows = ["| Recherche | Avant |", "|---|:---:|", "| Trousseau | **texte** exact |"]

        XCTAssertEqual(ReplyMarkdown.alignedTable(rows), [
            "Recherche  Avant",
            "Trousseau  texte exact",
        ])
    }

    func testAnOrderedListKeepsItsNumbers() {
        let blocks = ReplyMarkdown.blocks("1. un\n2. **deux**")

        XCTAssertEqual(blocks.map(\.kind), [.list(ordered: true)])
        XCTAssertEqual(blocks[0].copyText, "1. un\n2. deux")
    }

    func testAHeadingCopiesItsSectionUpToTheNextHeadingOfTheSameLevel() {
        let blocks = ReplyMarkdown.blocks("## Un\nA.\n### Sous\nB.\n## Deux\nC.")

        XCTAssertEqual(ReplyMarkdown.sectionText(startingAt: 0, in: blocks), "Un\n\nA.\n\nSous\n\nB.")
        XCTAssertEqual(ReplyMarkdown.sectionText(startingAt: 4, in: blocks), "Deux\n\nC.")
    }

    func testTheWholeReplyCopiesBlockByBlock() {
        XCTAssertEqual(ReplyMarkdown.plainText(ReplyMarkdown.blocks("# T\n\n*a*  b\n\n```\nc\n```")), "T\n\na  b\n\nc")
    }
}
