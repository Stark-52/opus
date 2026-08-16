// ArtifactsEmptyReason — why the drawer has nothing to show.
//
// Added after the drawer shipped and failed its owner on first contact. He
// opened it on a pane Opus had spawned but nobody had typed in, so Claude
// had never written a transcript for that session id. The drawer said "No
// artifacts in this session": true, and useless. He had no way to tell that
// from "the session is fine but produced nothing", or from "your filter
// hides everything".
//
// An earlier review flagged the collapse of these situations into one
// sentence and it was accepted on the grounds that the todo drawer and the
// context meter already do the same. That was the wrong call: those two
// surfaces answer questions you can also answer by looking at the terminal,
// and this one does not. The message is the ONLY thing the drawer can say
// when it is empty, so it has to earn its line.
//
// Order matters. Each case answers a question that only makes sense once
// the case above it has been ruled out, which is why `resolve` is a
// sequence of guards and not a lookup.

import Foundation

public enum ArtifactsEmptyReason: Equatable, Sendable, CaseIterable {
    /// No Claude session is bound to the active pane. Nothing downstream can
    /// be answered until that changes.
    case noSessionBound
    /// A session is bound, but no transcript exists for it on disk yet.
    /// Normal for a pane that has been opened and never used.
    case transcriptNotStarted
    /// The transcript exists and has been read; the session genuinely has
    /// not produced anything worth listing.
    case sessionHasNoArtifacts
    /// Artifacts exist, and the current chip or search text hides all of
    /// them. The only case the user can fix from inside the drawer.
    case filterExcludesAll

    public var message: String {
        switch self {
        case .noSessionBound: return "No session bound to this pane"
        case .transcriptNotStarted: return "This session has not started yet"
        case .sessionHasNoArtifacts: return "No artifacts in this session"
        case .filterExcludesAll: return "No match"
        }
    }

    /// `nil` when the list is not empty, so a caller can assign the whole
    /// empty-state in one expression rather than branching twice.
    public static func resolve(
        hasSession: Bool,
        hasTranscript: Bool,
        artifactCount: Int,
        visibleCount: Int
    ) -> ArtifactsEmptyReason? {
        guard visibleCount == 0 else { return nil }
        guard hasSession else { return .noSessionBound }
        guard hasTranscript else { return .transcriptNotStarted }
        guard artifactCount > 0 else { return .sessionHasNoArtifacts }
        return .filterExcludesAll
    }
}
