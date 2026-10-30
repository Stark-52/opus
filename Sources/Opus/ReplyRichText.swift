// ReplyRichText: a reply's blocks as the rich text Mail, Notes and Pages
// paste: headings, bold, italics, links, lists with their bullets showing,
// code in a fixed-width font, tables in columns on tab stops, each block
// spaced from the next.
//
// No colour, so the destination's own text colour fills it, light or
// dark; Helvetica Neue, which is how RTF names the system font anyway.
// The bullets are characters rather than a text list: a text list read
// back by TextKit 2 keeps its markers out of the text, and an editor that
// does not draw them shows a list with no bullets at all.

import AppKit

enum ReplyRichText {
    static let size: CGFloat = 13
    private static let body = NSFont(name: "HelveticaNeue", size: size) ?? .systemFont(ofSize: size)
    /// After a block; between a list's items or a table's rows, less.
    private static let blockSpacing: CGFloat = 8
    private static let itemSpacing: CGFloat = 2

    static func text(_ blocks: [ReplyBlock]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        blocks.forEach { result.append(text(for: $0)) }
        // Every paragraph ends with its break; the last one needs none.
        if result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }

    private static func text(for block: ReplyBlock) -> NSAttributedString {
        let first = block.items.first ?? ""
        switch block.kind {
        case .heading(let level):
            let scale: CGFloat = level == 1 ? 1.6 : level == 2 ? 1.35 : 1.15
            let font = bold(NSFont(descriptor: body.fontDescriptor, size: size * scale) ?? body)
            return paragraph(inline(first, font: font), style(before: 6, after: 4))
        case .paragraph:
            return paragraph(inline(first, font: body), style(after: blockSpacing))
        case .quote:
            return paragraph(inline(first, font: italic(body)), style(indent: 18, after: blockSpacing))
        case .list:
            return list(block)
        case .code:
            let lines = first.components(separatedBy: "\n")
            let result = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                let spacing = index == lines.count - 1 ? blockSpacing : 0
                result.append(paragraph(NSAttributedString(string: line, attributes: [.font: mono(size - 1)]),
                                        style(indent: 12, after: spacing)))
            }
            return result
        case .table:
            return table(block.items)
        case .rule:
            return NSAttributedString()
        }
    }

    /// One paragraph per item, the bullet (or the number as written) hung
    /// in front so wrapped lines align with the text.
    private static func list(_ block: ReplyBlock) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, (marker, item)) in zip(block.markers, block.items).enumerated() {
            let depth = marker.prefix { $0 == " " }.count / 2
            let written = marker.trimmingCharacters(in: .whitespaces)
            let bullet = written.first?.isNumber == true ? written : depth == 0 ? "•" : "◦"
            let line = NSMutableAttributedString(string: bullet + "\t", attributes: [.font: body])
            line.append(inline(item, font: body))
            let spacing = index == block.items.count - 1 ? blockSpacing : itemSpacing
            result.append(paragraph(line, style(indent: CGFloat(depth) * 18, hanging: 18, after: spacing)))
        }
        return result
    }

    /// Cells separated by tabs, on stops set past each column's widest
    /// cell: lined up in Notes or Mail, one cell per column in Numbers.
    private static func table(_ rows: [String]) -> NSAttributedString {
        let cells = ReplyMarkdown.tableCells(rows).enumerated().map { index, row in
            row.map { inline($0, font: index == 0 ? bold(body) : body) }
        }
        let columns = cells.map(\.count).max() ?? 0
        var stops: [NSTextTab] = []
        var position: CGFloat = 0
        for column in 0..<max(columns - 1, 0) {
            position += (cells.map { column < $0.count ? $0[column].size().width : 0 }.max() ?? 0) + 16
            stops.append(NSTextTab(textAlignment: .left, location: position.rounded(.up)))
        }
        let result = NSMutableAttributedString()
        for (index, row) in cells.enumerated() {
            let line = NSMutableAttributedString()
            for (column, cell) in row.enumerated() {
                if column > 0 { line.append(NSAttributedString(string: "\t", attributes: [.font: body])) }
                line.append(cell)
            }
            let paragraphStyle = style(after: index == cells.count - 1 ? blockSpacing : itemSpacing)
            paragraphStyle.tabStops = stops
            result.append(paragraph(line, paragraphStyle))
        }
        return result
    }

    /// Inline markdown (bold, italic, strikethrough, code, links) in `font`.
    private static func inline(_ markdown: String, font: NSFont) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: font])
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var attributes: [NSAttributedString.Key: Any] = [:]
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { runFont = mono(font.pointSize - 1) }
                if intent.contains(.stronglyEmphasized) { runFont = bold(runFont) }
                if intent.contains(.emphasized) { runFont = italic(runFont) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = runFont
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    /// `content` and its break, under one paragraph style.
    private static func paragraph(_ content: NSAttributedString, _ style: NSParagraphStyle) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: content)
        result.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func style(indent: CGFloat = 0, hanging: CGFloat = 0, before: CGFloat = 0,
                              after: CGFloat) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = indent
        style.headIndent = indent + hanging
        if hanging > 0 { style.tabStops = [NSTextTab(textAlignment: .left, location: indent + hanging)] }
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    private static func mono(_ size: CGFloat) -> NSFont {
        NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    private static func italic(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
    }
}
