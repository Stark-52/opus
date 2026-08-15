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
        // Clamped, and compared with >=, because the loop below used to test
        // `result.count == capacity`: at capacity 0 (or any negative value)
        // that equality can never fire from a count that only ever grows
        // past it, so "keep nothing" returned EVERYTHING. Verified by
        // execution, not by reading. Unreachable from today's single caller,
        // which passes the fixed 500, but the function is public.
        let cap = max(capacity, 0)
        guard cap > 0 else { return [] }

        var seen = Set<String>()
        var result: [Artifact] = []
        result.reserveCapacity(min(existing.count + incoming.count, cap))

        for artifact in incoming.reversed() + existing {
            guard seen.insert(artifact.key).inserted else { continue }
            result.append(artifact)
            if result.count >= cap { break }
        }
        return result
    }
}
