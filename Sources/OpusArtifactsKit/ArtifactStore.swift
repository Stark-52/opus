// ArtifactStore — a pure reducer over an ordered array.
//
// Recency is POSITION IN THE TRANSCRIPT, never file modification date. A
// file created months ago that Claude just edited belongs at the top; its
// mtime would agree, but a file it merely re-mentioned would not, and the
// drawer is a record of the conversation, not of the filesystem.

import Foundation

public enum ArtifactStore {
    /// No observed session comes close. This is a runaway guard, not a
    /// product limit.
    public static let capacity = 500

    /// `incoming` is in transcript order (oldest first). The result is
    /// newest first, deduplicated by `key`, with a repeat mention moving
    /// its artifact to the top rather than adding a second row.
    public static func merge(
        existing: [Artifact],
        incoming: [Artifact],
        capacity: Int = ArtifactStore.capacity
    ) -> [Artifact] {
        guard !incoming.isEmpty else { return existing }

        var seen = Set<String>()
        var result: [Artifact] = []
        result.reserveCapacity(min(existing.count + incoming.count, capacity))

        for artifact in incoming.reversed() + existing {
            guard seen.insert(artifact.key).inserted else { continue }
            result.append(artifact)
            if result.count == capacity { break }
        }
        return result
    }
}
