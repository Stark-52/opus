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
}
