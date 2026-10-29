// ReplyMarkdown — a reply cut into the blocks the reply drawer draws and
// copies one by one.
//
// Line-based and deliberately small: headings, paragraphs, lists, fenced
// code, tables, quotes and rules, which is what Claude's answers are made
// of. Prose copies as plain text, markers stripped, because it is pasted
// into messages and posts; code copies as the code; a table copies as
// written, since that is how it pastes into Notion or a README.

import Foundation

struct ReplyBlock: Equatable {
    enum Kind: Equatable {
        case heading(level: Int)
        case paragraph
        case list(ordered: Bool)
        case code(language: String)
        case table
        case quote
        case rule
    }

    let kind: Kind
    /// Inline markdown the drawer renders: the heading's text, the joined
    /// paragraph or quote, one entry per list item, the code body, the
    /// table's rows.
    let items: [String]
    /// A list item's marker as written ("-", "2.", with its indentation).
    let markers: [String]

    init(_ kind: Kind, items: [String], markers: [String] = []) {
        self.kind = kind
        self.items = items
        self.markers = markers
    }

    /// What the block's copy button puts on the clipboard.
    var copyText: String {
        switch kind {
        case .heading, .paragraph, .quote:
            return items.map(ReplyMarkdown.plain).joined(separator: " ")
        case .list:
            return zip(markers, items).map { "\($0) \(ReplyMarkdown.plain($1))" }.joined(separator: "\n")
        case .code, .table:
            return items.joined(separator: "\n")
        case .rule:
            return ""
        }
    }
}

enum ReplyMarkdown {
    static func blocks(_ text: String) -> [ReplyBlock] {
        let lines = text.components(separatedBy: "\n")
        var blocks: [ReplyBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(ReplyBlock(.paragraph, items: [paragraph.joined(separator: " ")]))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(ReplyBlock(.code(language: language), items: [body.joined(separator: "\n")]))
            } else if let (level, title) = heading(trimmed) {
                flushParagraph()
                blocks.append(ReplyBlock(.heading(level: level), items: [title]))
                index += 1
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(ReplyBlock(.rule, items: []))
                index += 1
            } else if trimmed.hasPrefix("|") {
                flushParagraph()
                var rows: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(ReplyBlock(.table, items: rows))
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    let body = lines[index].trimmingCharacters(in: .whitespaces).dropFirst()
                    quoted.append(body.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(ReplyBlock(.quote, items: [quoted.joined(separator: " ")]))
            } else if let first = listItem(line) {
                flushParagraph()
                var markers = [first.marker]
                var items = [first.text]
                index += 1
                while index < lines.count {
                    let next = lines[index]
                    if let item = listItem(next) {
                        markers.append(item.marker)
                        items.append(item.text)
                    } else if next.first?.isWhitespace == true, !next.trimmingCharacters(in: .whitespaces).isEmpty {
                        items[items.count - 1] += " " + next.trimmingCharacters(in: .whitespaces)
                    } else if next.trimmingCharacters(in: .whitespaces).isEmpty,
                              index + 1 < lines.count, listItem(lines[index + 1]) != nil {
                        // A blank line between two items keeps the list going.
                    } else {
                        break
                    }
                    index += 1
                }
                let ordered = first.marker.trimmingCharacters(in: .whitespaces).first?.isNumber == true
                blocks.append(ReplyBlock(.list(ordered: ordered), items: items, markers: markers))
            } else {
                paragraph.append(trimmed)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    /// A heading copies its whole section: itself and every block up to the
    /// next heading of the same or a higher level. Any other block copies
    /// itself.
    static func sectionText(startingAt index: Int, in blocks: [ReplyBlock]) -> String {
        guard blocks.indices.contains(index) else { return "" }
        guard case .heading(let level) = blocks[index].kind else { return blocks[index].copyText }

        var end = index + 1
        while end < blocks.count {
            if case .heading(let next) = blocks[end].kind, next <= level { break }
            end += 1
        }
        return plainText(Array(blocks[index..<end]))
    }

    static func plainText(_ blocks: [ReplyBlock]) -> String {
        blocks.map(\.copyText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A table's rows as the drawer draws them, in a monospaced font: cells
    /// in plain text, padded to their column's width, the `|---|` row gone.
    static func alignedTable(_ rows: [String]) -> [String] {
        let cells = rows.map { row in
            row.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                .components(separatedBy: "|")
                .map { plain($0.trimmingCharacters(in: .whitespaces)) }
        }.filter { row in
            !row.allSatisfy { $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }
        }
        let columns = cells.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            cells.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0
        }
        return cells.map { row in
            row.enumerated().map { column, cell in
                column == row.count - 1 ? cell : cell.padding(toLength: widths[column], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }

    /// Inline markdown to plain text: emphasis and code markers dropped, a
    /// link kept as its text with the address after it.
    static func plain(_ inline: String) -> String {
        var text = inline
        let rules: [(String, String)] = [
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "$1 ($2)"),
            (#"`([^`]+)`"#, "$1"),
            (#"\*\*(.+?)\*\*"#, "$1"),
            (#"__(.+?)__"#, "$1"),
            (#"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])"#, "$1"),
            (#"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])"#, "$1"),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard let match = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) else { return nil }
        let level = line[match].filter { $0 == "#" }.count
        let title = line[match.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        return (level, title)
    }

    private static func isRule(_ line: String) -> Bool {
        line.range(of: #"^(\*\s*){3,}$|^(-\s*){3,}$|^(_\s*){3,}$"#, options: .regularExpression) != nil
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        guard let match = line.range(of: #"^\s*([-*+]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
        let marker = line[match].trimmingCharacters(in: .whitespaces)
        let indent = String(line.prefix { $0 == " " })
        return (indent + marker, String(line[match.upperBound...]))
    }
}
