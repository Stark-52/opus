// ReplyHTMLTests: the formatted copy of a reply, as the HTML a rich editor
// (Notes, Mail, Google Docs, Notion, Slack, Medium) pastes as headings,
// bold, lists, links, code and tables instead of bare text.

import XCTest
@testable import Opus

final class ReplyHTMLTests: XCTestCase {
    private func html(_ markdown: String) -> String {
        ReplyHTML.body(ReplyMarkdown.blocks(markdown))
    }

    func testHeadingsAndParagraphsKeepTheirInlineFormatting() {
        XCTAssertEqual(html("## Titre\nUn **mot**, *penché*, `code` et [lien](https://example.com/?a=1&b=2)."),
                       "<h2>Titre</h2>"
                       + "<p>Un <strong>mot</strong>, <em>penché</em>, <code>code</code> et "
                       + "<a href=\"https://example.com/?a=1&amp;b=2\">lien</a>.</p>")
    }

    func testTextIsEscaped() {
        XCTAssertEqual(html("a < b & c > d"), "<p>a &lt; b &amp; c &gt; d</p>")
    }

    func testAListNestsByIndentation() {
        XCTAssertEqual(html("- un\n  - sous\n- deux"),
                       "<ul><li>un<ul><li>sous</li></ul></li><li>deux</li></ul>")
    }

    func testAnOrderedListIsNumbered() {
        XCTAssertEqual(html("1. un\n2. **deux**"), "<ol><li>un</li><li><strong>deux</strong></li></ol>")
    }

    func testCodeIsPreformattedAndEscaped() {
        XCTAssertEqual(html("```swift\nif a < b {\n    go()\n}\n```"),
                       "<pre><code>if a &lt; b {\n    go()\n}</code></pre>")
    }

    func testATableHasAHeaderRowAndNoSeparatorRow() {
        XCTAssertEqual(html("| A | B |\n|---|:---:|\n| 1 | **2** |"),
                       "<table><thead><tr><th>A</th><th>B</th></tr></thead>"
                       + "<tbody><tr><td>1</td><td><strong>2</strong></td></tr></tbody></table>")
    }

    func testQuotesAndRules() {
        XCTAssertEqual(html("> une citation\n\n---"), "<blockquote><p>une citation</p></blockquote><hr>")
    }

    func testTheDocumentDeclaresUTF8SoAccentsSurviveThePaste() {
        let document = ReplyHTML.document(ReplyMarkdown.blocks("Déjà"))

        XCTAssertTrue(document.hasPrefix("<meta charset=\"utf-8\">"))
        XCTAssertTrue(document.hasSuffix("<p>Déjà</p>"))
    }
}
