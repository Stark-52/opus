// ArtifactKindFilter — the drawer's per-kind lens.
//
// Added after the feature was first run against real transcripts, where
// folders and project roots took rows 5 to 11. Those are genuinely cited
// paths, so dropping them in the classifier would be wrong, and ranking
// files above folders would bake one preference in permanently. A lens
// lets the choice be made per moment instead.
//
// `files` deliberately excludes images. Two chips whose sets overlapped
// would show counts that do not add up to the whole, and the partition
// test below is what keeps that honest.

import Foundation

public enum ArtifactKindFilter: String, CaseIterable, Equatable, Sendable {
    case all, files, images, links, folders

    public var title: String {
        switch self {
        case .all: return "All"
        case .files: return "Files"
        case .images: return "Images"
        case .links: return "Links"
        case .folders: return "Folders"
        }
    }

    public func matches(_ artifact: Artifact) -> Bool {
        switch self {
        case .all: return true
        case .files: return artifact.kind == .file
        case .images: return artifact.kind == .image
        case .links: return artifact.kind == .url
        case .folders: return artifact.kind == .folder
        }
    }

    public static func apply(_ filter: ArtifactKindFilter, to artifacts: [Artifact]) -> [Artifact] {
        filter == .all ? artifacts : artifacts.filter { filter.matches($0) }
    }

    /// The next chip left or right of `current`, wrapping around the row.
    /// Only the SIGN of `direction` is read.
    ///
    /// Chips that would show nothing are skipped, because the two callers
    /// both have a reason not to land on an empty one: from the drawer it
    /// means arrowing into a blank list, and from an open preview it means
    /// handing QuickLook zero items, which is how the panel decides to close
    /// itself. `candidates` is what each caller counts as showable — every
    /// artifact for the drawer, only the ones with a file behind them for
    /// the preview.
    ///
    /// Returns `current` unchanged when no other chip qualifies, so a
    /// session whose artifacts are all one kind simply stays put.
    public static func step(from current: ArtifactKindFilter,
                            direction: Int,
                            keeping candidates: [Artifact]) -> ArtifactKindFilter {
        let cases = allCases
        guard direction != 0, let start = cases.firstIndex(of: current) else { return current }
        let stride = direction > 0 ? 1 : -1
        var index = start
        // At most one full lap: the last step lands back on `current`, which
        // is exactly the value we want to fall out with anyway.
        for _ in cases.indices {
            index = (index + stride + cases.count) % cases.count
            let candidate = cases[index]
            if candidates.contains(where: { candidate.matches($0) }) { return candidate }
        }
        return current
    }
}
