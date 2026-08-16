// ArtifactCandidate — one thing the transcript mentioned, before the disk
// has had a say. A candidate is not yet an artifact: the path is raw and
// unresolved, and it may name nothing at all. ArtifactClassifier turns a
// candidate into an Artifact, or drops it.

import Foundation

public struct ArtifactCandidate: Equatable, Sendable {
    public enum Payload: Equatable, Sendable {
        /// Raw token exactly as it appeared, unexpanded and unresolved.
        case path(String)
        /// Already validated as parseable with an http or https scheme.
        case url(String)
    }

    public let payload: Payload
    /// The working directory of the transcript entry this came from. A
    /// relative path means nothing without it, and it varies line to line
    /// in a session that changed project.
    public let cwd: String
    /// The transcript entry's own timestamp, carried through so the artifact
    /// can be ordered against artifacts from a different session.
    public let timestamp: Date?

    public init(payload: Payload, cwd: String, timestamp: Date? = nil) {
        self.payload = payload
        self.cwd = cwd
        self.timestamp = timestamp
    }
}
