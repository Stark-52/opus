// ReplyHTML: a reply's blocks as plain semantic HTML, the formatted copy a
// rich editor pastes as headings, bold, lists, links, code and tables.
//
// No styles: a paste takes the destination's own font and colours, the
// way text copied from a web page does. ReplyClipboard puts it on the
// clipboard next to the plain text, so a place that takes only text still
// gets the plain version.

import Foundation

enum ReplyHTML {
    /// The fragment with the charset declared first: an HTML clipboard
    /// read without it decodes "é" as two Latin-1 characters.
    static func document(_ blocks: [ReplyBlock]) -> String {
        "<meta charset=\"utf-8\">" + body(blocks)
    }

    static func body(_ blocks: [ReplyBlock]) -> String {
        blocks.map(block).joined()
    }

    private static func block(_ block: ReplyBlock) -> String {
        switch block.kind {
        case .heading(let level):
            return "<h\(level)>\(inline(block.items.first ?? ""))</h\(level)>"
        case .paragraph:
            return "<p>\(inline(block.items.first ?? ""))</p>"
        case .quote:
            return "<blockquote><p>\(inline(block.items.first ?? ""))</p></blockquote>"
        case .list:
            return list(block)
        case .code:
            return "<pre><code>\(escape(block.items.joined(separator: "\n")))</code></pre>"
        case .table:
            return table(block.items)
        case .rule:
            return "<hr>"
        }
    }

    /// Items nest by their marker's indentation, two spaces a level, and
    /// each level is numbered or not by its own marker.
    private static func list(_ block: ReplyBlock) -> String {
        var html = ""
        var open: [(depth: Int, tag: String)] = []
        for (marker, item) in zip(block.markers, block.items) {
            let depth = marker.prefix { $0 == " " }.count / 2
            let tag = marker.trimmingCharacters(in: .whitespaces).first?.isNumber == true ? "ol" : "ul"
            while let last = open.last, last.depth > depth {
                html += "</li></\(last.tag)>"
                open.removeLast()
            }
            if let last = open.last, last.depth == depth {
                html += "</li>"
                if last.tag != tag {
                    html += "</\(last.tag)><\(tag)>"
                    open[open.count - 1].tag = tag
                }
            } else {
                html += "<\(tag)>"
                open.append((depth, tag))
            }
            html += "<li>" + inline(item)
        }
        for level in open.reversed() { html += "</li></\(level.tag)>" }
        return html
    }

    private static func table(_ rows: [String]) -> String {
        let cells = ReplyMarkdown.tableCells(rows)
        guard let header = cells.first else { return "" }
        let head = "<tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
        let body = cells.dropFirst().map { row in "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
        return "<table><thead>\(head)</thead><tbody>\(body.joined())</tbody></table>"
    }

    /// Inline markdown (bold, italic, strikethrough, code, links) as HTML.
    static func inline(_ markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else { return escape(markdown) }
        return parsed.runs.map { run in
            var html = escape(String(parsed[run.range].characters))
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { html = "<code>\(html)</code>" }
                if intent.contains(.strikethrough) { html = "<del>\(html)</del>" }
                if intent.contains(.emphasized) { html = "<em>\(html)</em>" }
                if intent.contains(.stronglyEmphasized) { html = "<strong>\(html)</strong>" }
            }
            if let link = run.link { html = "<a href=\"\(escape(link.absoluteString))\">\(html)</a>" }
            return html
        }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
