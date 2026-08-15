// TranscriptArtifactExtractor — one JSONL line in, candidates out.
//
// Deliberately narrow about what it looks at:
//   - only `assistant` entries, because a path the user typed is a path the
//     user already knows the location of;
//   - never `tool_result`, because a Read result is an entire file and
//     would flood the drawer with hundreds of paths that were neither
//     produced nor mentioned;
//   - never `thinking`, because what the model considered is not what it
//     produced.
//
// Same shape as SessionIndex.parseSummary: pure, side-effect free, and
// tolerant of every malformed line rather than throwing on any of them. A
// live transcript is written by another process; half a line is normal.

import Foundation

public enum TranscriptArtifactExtractor {

    public static func candidates(fromLine line: Data) -> [ArtifactCandidate] {
        guard !line.isEmpty,
              let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              root["type"] as? String == "assistant",
              let cwd = root["cwd"] as? String,
              let message = root["message"] as? [String: Any]
        else { return [] }

        // message.content is either a String or an array of blocks. Both
        // shapes are live in real transcripts.
        if let text = message["content"] as? String {
            return scanText(text, cwd: cwd)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }

        var result: [ArtifactCandidate] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String {
                    result.append(contentsOf: scanText(text, cwd: cwd))
                }
            case "tool_use":
                result.append(contentsOf: fromToolUse(block, cwd: cwd))
            default:
                continue
            }
        }
        return result
    }

    private static func scanText(_ text: String, cwd: String) -> [ArtifactCandidate] {
        TextArtifactScanner.urls(in: text).map { ArtifactCandidate(payload: .url($0), cwd: cwd) }
            + TextArtifactScanner.paths(in: text).map { ArtifactCandidate(payload: .path($0), cwd: cwd) }
    }

    private static func fromToolUse(_ block: [String: Any], cwd: String) -> [ArtifactCandidate] {
        guard let name = block["name"] as? String,
              !ArtifactRuleTable.deniedTools.contains(name),
              let input = block["input"] as? [String: Any]
        else { return [] }

        var result: [ArtifactCandidate] = []
        for (key, value) in input.sorted(by: { $0.key < $1.key }) {
            if ArtifactRuleTable.urlKeys.contains(key), let s = value as? String {
                if TextArtifactScanner.urls(in: s).first == s { result.append(.init(payload: .url(s), cwd: cwd)) }
            } else if ArtifactRuleTable.pathKeys.contains(key) {
                if let s = value as? String {
                    result.append(.init(payload: .path(s), cwd: cwd))
                } else if let many = value as? [String] {
                    result.append(contentsOf: many.map { .init(payload: .path($0), cwd: cwd) })
                }
            } else if ArtifactRuleTable.textScanKeys.contains(key), let s = value as? String {
                result.append(contentsOf: scanText(s, cwd: cwd))
            }
        }
        return result
    }
}
