// ArtifactStore — a pure reducer over an ordered array.
//
// Recency is POSITION IN THE TRANSCRIPT, never file modification date. A
// file created months ago that Claude just edited belongs at the top; its
// mtime would agree, but a file it merely re-mentioned would not, and the
// drawer is a record of the conversation, not of the filesystem.

import Foundation

public enum ArtifactStore {
    /// A dated artifact always beats an undated one; between two dated ones
    /// the later wins.
    private static func isNewer(_ a: Artifact, than b: Artifact) -> Bool {
        switch (a.timestamp, b.timestamp) {
        case let (x?, y?): return x > y
        case (_?, nil): return true
        default: return false
        }
    }

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

        // Deduplicate first, keeping whichever copy carries the newer
        // timestamp. The same file written twice is one row, dated by its
        // latest write, and an undated copy never displaces a dated one.
        var best: [String: Artifact] = [:]
        var order: [String] = []
        for artifact in incoming.reversed() + existing {
            guard let held = best[artifact.key] else {
                best[artifact.key] = artifact
                order.append(artifact.key)
                continue
            }
            if isNewer(artifact, than: held) { best[artifact.key] = artifact }
        }

        // Then order by the shared clock. Position within one transcript
        // cannot order two transcripts against each other; a timestamp can,
        // and that is what lets an aggregated drawer interleave two sessions
        // instead of stacking one batch on the other. Ties and undated
        // artifacts fall back to the order they were seen in, which keeps the
        // result stable rather than arbitrary.
        var rank: [String: Int] = [:]
        for (i, key) in order.enumerated() { rank[key] = i }
        let sorted = order.compactMap { best[$0] }.sorted { a, b in
            switch (a.timestamp, b.timestamp) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false   // undated cannot claim to be recent
            case (_?, nil): return true
            default: return (rank[a.key] ?? 0) < (rank[b.key] ?? 0)
            }
        }
        return Array(sorted.prefix(cap))
    }
}
