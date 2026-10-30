// ArtifactRows: what the artifacts drawer's table shows, row by row: a
// header per moment, that moment's images three to a strip (the thing a
// person comes to open), then its other artifacts one per row.

import Foundation

public enum ArtifactRow: Equatable {
    case header(String)
    case images([Artifact])
    case item(Artifact)
}

public enum ArtifactRows {
    public static let imagesPerRow = 3

    public static func make(_ sections: [ArtifactSection], calendar: Calendar) -> [ArtifactRow] {
        sections.flatMap { section -> [ArtifactRow] in
            let strips = stride(from: 0, to: section.images.count, by: imagesPerRow).map {
                ArtifactRow.images(Array(section.images[$0..<min($0 + imagesPerRow, section.images.count)]))
            }
            return [.header(section.moment.title(calendar: calendar))] + strips + section.others.map(ArtifactRow.item)
        }
    }

    /// Every artifact in the order the rows show them, which is the order
    /// the arrow keys walk.
    public static func displayOrder(_ rows: [ArtifactRow]) -> [Artifact] {
        rows.flatMap { row -> [Artifact] in
            switch row {
            case .header: return []
            case .images(let images): return images
            case .item(let artifact): return [artifact]
            }
        }
    }
}
