// ReplyClipboard: what a copy button of the reply drawer puts on the
// clipboard. Prose and sections go in three versions at once and each
// destination takes the richest one it reads: HTML (ReplyHTML) for a
// browser (Google Docs, Notion, Slack, Medium, Gmail), RTF (ReplyRichText)
// for Mail, Notes and Pages, plain text for a terminal, a message or a
// post. A code block alone goes as its code and nothing else, since it is
// pasted into an editor or a terminal.

import AppKit

enum ReplyClipboard {
    /// False when there is nothing to copy (a rule, an empty reply).
    @discardableResult
    static func write(_ blocks: [ReplyBlock], to board: NSPasteboard) -> Bool {
        let plain = ReplyMarkdown.plainText(blocks)
        guard !plain.isEmpty else { return false }
        board.clearContents()
        let codeOnly = blocks.allSatisfy { if case .code = $0.kind { return true } else { return false } }
        if !codeOnly {
            board.setString(ReplyHTML.document(blocks), forType: .html)
            if let rtf = rtf(blocks) { board.setData(rtf, forType: .rtf) }
        }
        return board.setString(plain, forType: .string)
    }

    static func rtf(_ blocks: [ReplyBlock]) -> Data? {
        let rich = ReplyRichText.text(blocks)
        return rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])
    }
}
