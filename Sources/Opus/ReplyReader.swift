// ReplyReader — the answer the reply drawer shows, read off the transcript.
//
// The answer is the text Claude wrote after the last tool call of the
// latest turn: text followed by a tool call is running commentary ("looking
// at the code…"). A turn that has not written its answer yet, because it is
// still between tool calls, leaves the previous answer showing rather than
// the commentary or a blank drawer. Subagent records
// (`isSidechain`) are someone else's text and are skipped.

import Foundation

enum ReplyReader {
    /// Bytes first read off the end of the transcript. A long answer runs to
    /// tens of kilobytes; behind it, a long turn's tool results can push the
    /// previous answer megabytes back, hence the widening below.
    static let tailBudgetBytes = 512 * 1024
    static let maxTailBudgetBytes = 32 * 1024 * 1024

    /// Reads ever larger tails (four times larger each time) until one holds
    /// an answer, the whole file has been read, or `maxBudget` is reached.
    /// `readTail` returns the last `budget` bytes, or fewer for a smaller file.
    static func lastReply(startBudget: Int = tailBudgetBytes, maxBudget: Int = maxTailBudgetBytes,
                          readTail: (Int) -> Data?) -> String? {
        var budget = startBudget
        while let tail = readTail(budget) {
            if let reply = lastReply(fromTranscriptTail: tail) { return reply }
            guard tail.count >= budget, budget < maxBudget else { return nil }
            budget = min(budget * 4, maxBudget)
        }
        return nil
    }

    static func lastReply(fromTranscriptTail data: Data) -> String? {
        var previous: String?
        var sinceLastTool: [String] = []

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  record["isSidechain"] as? Bool != true,
                  let message = record["message"] as? [String: Any]
            else { continue }

            switch record["type"] as? String {
            case "user":
                if Self.isToolResult(message["content"]) {
                    sinceLastTool = []
                } else {
                    if let reply = Self.reply(sinceLastTool) { previous = reply }
                    sinceLastTool = []
                }
            case "assistant":
                // A record holding a tool call makes everything said so far
                // in the turn commentary, its own text included.
                if Self.isToolUse(message["content"]) {
                    sinceLastTool = []
                } else {
                    sinceLastTool += Self.texts(message["content"])
                }
            default:
                continue
            }
        }
        return Self.reply(sinceLastTool) ?? previous
    }

    private static func reply(_ texts: [String]) -> String? {
        texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }

    private static func isToolUse(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_use" }
    }

    private static func isToolResult(_ content: Any?) -> Bool {
        guard let blocks = content as? [[String: Any]] else { return false }
        return blocks.contains { $0["type"] as? String == "tool_result" }
    }

    private static func texts(_ content: Any?) -> [String] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text",
                  let text = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty
            else { return nil }
            return text
        }
    }
}
