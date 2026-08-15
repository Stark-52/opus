// TranscriptArtifactReader — turn a session transcript into an ordered
// artifact list, incrementally.
//
// Measured 15 August 2026 on the largest transcript present (53.8 MB,
// 12 753 lines): 180 ms for a full parse in Python, a generous upper bound
// for JSONSerialization. That measurement is why this reads the WHOLE file
// on first call, with no byte budget and no substring prefilter, unlike
// SessionIndex.scan and TerminalContainerView.readTranscriptTail which
// both work to a fixed budget. Those budgets exist because nobody had
// measured, not because a full read was too slow.
//
// Called from a background queue only. Nothing here touches AppKit.

import Foundation

public struct TranscriptReadResult: Equatable, Sendable {
    public let artifacts: [Artifact]
    public let offset: UInt64

    public init(artifacts: [Artifact], offset: UInt64) {
        self.artifacts = artifacts
        self.offset = offset
    }
}

public enum TranscriptArtifactReader {

    public static func read(
        url: URL,
        from offset: UInt64,
        existing: [Artifact],
        fileManager: FileManager = .default,
        isImage: (String) -> Bool = ArtifactClassifier.defaultIsImage
    ) -> TranscriptReadResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return TranscriptReadResult(artifacts: existing, offset: offset)
        }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd() else {
            return TranscriptReadResult(artifacts: existing, offset: offset)
        }

        // A file smaller than the stored offset was replaced or rotated.
        // Resuming from the stale offset would read nothing, silently, for
        // the rest of the session.
        var start = offset
        var carried = existing
        if size < offset {
            start = 0
            carried = []
        }
        guard size > start else {
            return TranscriptReadResult(artifacts: revalidate(carried, fileManager: fileManager),
                                        offset: start)
        }

        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return TranscriptReadResult(artifacts: carried, offset: start) }

        // Stop at the last complete line. The transcript is appended to by
        // another process, so the tail is routinely half a line; consuming
        // it would both fail to parse and skip past the completed form.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return TranscriptReadResult(artifacts: revalidate(carried, fileManager: fileManager),
                                        offset: start)
        }
        let complete = data[data.startIndex...lastNewline]

        var incoming: [Artifact] = []
        for line in complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            for candidate in TranscriptArtifactExtractor.candidates(fromLine: Data(line)) {
                if let artifact = ArtifactClassifier.classify(
                    candidate, fileManager: fileManager, isImage: isImage) {
                    incoming.append(artifact)
                }
            }
        }

        let merged = ArtifactStore.merge(existing: carried, incoming: incoming)
        return TranscriptReadResult(
            artifacts: revalidate(merged, fileManager: fileManager),
            offset: start + UInt64(complete.count))
    }

    /// Drop artifacts whose file has since been deleted. A few hundred
    /// `stat` calls, on the same background queue as the read itself.
    private static func revalidate(_ list: [Artifact], fileManager: FileManager) -> [Artifact] {
        list.filter { artifact in
            guard let path = artifact.resolvedPath else { return true }
            return fileManager.fileExists(atPath: path)
        }
    }
}
