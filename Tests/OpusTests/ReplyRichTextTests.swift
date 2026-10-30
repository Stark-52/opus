// ReplyRichTextTests: the rich text a reply copies as for Mail, Notes and
// Pages, read back from its RTF the way those apps read it.

import XCTest
import AppKit
@testable import Opus

final class ReplyRichTextTests: XCTestCase {
    private func pasted(_ markdown: String) throws -> NSAttributedString {
        let rich = ReplyRichText.text(ReplyMarkdown.blocks(markdown))
        let rtf = try XCTUnwrap(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]))
        return try XCTUnwrap(NSAttributedString(rtf: rtf, documentAttributes: nil))
    }

    private func style(of text: String, in rich: NSAttributedString) throws -> NSParagraphStyle {
        let range = (rich.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, text)
        return try XCTUnwrap(rich.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func font(of text: String, in rich: NSAttributedString) throws -> NSFont {
        let range = (rich.string as NSString).range(of: text)
        XCTAssertNotEqual(range.location, NSNotFound, text)
        return try XCTUnwrap(rich.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    func testBlocksArePlainParagraphsWithoutATrailingBreak() throws {
        XCTAssertEqual(try pasted("## Titre\nUn mot.\n\n> cité").string, "Titre\nUn mot.\ncité")
    }

    func testAListKeepsItsBulletsAndNumbersAndHangsItsLines() throws {
        let rich = try pasted("- un\n  - sous\n- deux\n\n1. premier\n2. second")

        XCTAssertEqual(rich.string, "•\tun\n◦\tsous\n•\tdeux\n1.\tpremier\n2.\tsecond")
        let top = try style(of: "•\tun", in: rich)
        let nested = try style(of: "◦\tsous", in: rich)
        XCTAssertGreaterThan(top.headIndent, top.firstLineHeadIndent, "wrapped lines align with the text, not the bullet")
        XCTAssertGreaterThan(nested.firstLineHeadIndent, top.firstLineHeadIndent)
    }

    func testBlocksAreSpacedApart() throws {
        let rich = try pasted("Un.\n\n- a\n- b\n\nDeux.")

        XCTAssertGreaterThan(try style(of: "Un.", in: rich).paragraphSpacing, 0)
        XCTAssertGreaterThan(try style(of: "•\tb", in: rich).paragraphSpacing,
                             try style(of: "•\ta", in: rich).paragraphSpacing, "a list's last item ends the block")
    }

    func testInlineFormattingAndLinks() throws {
        let rich = try pasted("Un **gras**, *penché*, `code` et [lien](https://example.com).")

        XCTAssertTrue(try font(of: "gras", in: rich).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(of: "penché", in: rich).fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertTrue(try font(of: "code", in: rich).isFixedPitch)
        XCTAssertEqual(try font(of: "Un", in: rich).familyName, "Helvetica Neue")
        XCTAssertEqual(try font(of: "Un", in: rich).pointSize, 13)
        let link = (rich.string as NSString).range(of: "lien")
        XCTAssertEqual((rich.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString
                       ?? rich.attribute(.link, at: link.location, effectiveRange: nil) as? String,
                       "https://example.com")
    }

    func testCodeIsFixedWidthAndAQuoteIsIndented() throws {
        let rich = try pasted("```\nlet a = 1\nlet b = 2\n```\n\n> cité")

        XCTAssertTrue(try font(of: "let b", in: rich).isFixedPitch)
        XCTAssertGreaterThan(try style(of: "cité", in: rich).firstLineHeadIndent, 0)
    }

    func testATableLinesItsColumnsUpOnTabStops() throws {
        let rich = try pasted("| Fichier | État |\n|---|---|\n| Opus.app | **installé** |")

        XCTAssertEqual(rich.string, "Fichier\tÉtat\nOpus.app\tinstallé")
        XCTAssertTrue(try font(of: "Fichier", in: rich).fontDescriptor.symbolicTraits.contains(.bold), "the header row")
        XCTAssertEqual(try style(of: "Fichier", in: rich).tabStops.map(\.location),
                       try style(of: "Opus.app", in: rich).tabStops.map(\.location))
        XCTAssertEqual(try style(of: "Opus.app", in: rich).tabStops.count, 1)
    }

    func testNothingIsColoured() throws {
        let rich = try pasted("## T\nUn **mot** et [lien](https://example.com).\n\n```\nx\n```")
        var colored: [String] = []
        rich.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
            if value != nil { colored.append((rich.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(colored, [])
    }
}
