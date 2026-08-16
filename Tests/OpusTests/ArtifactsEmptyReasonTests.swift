import XCTest
@testable import OpusArtifactsKit

/// Written after the drawer shipped and immediately told its owner nothing
/// useful. He opened it on a pane whose session had never been used, and it
/// said "No artifacts in this session" - literally true, and no help at all
/// in working out why. Four situations were collapsed into one sentence.
final class ArtifactsEmptyReasonTests: XCTestCase {

    func testNothingIsWrongWhenSomethingIsVisible() {
        XCTAssertNil(ArtifactsEmptyReason.resolve(
            hasSession: true, hasTranscript: true, artifactCount: 3, visibleCount: 3))
    }

    func testNoSessionBoundOutranksEverythingElse() {
        // Without a session the other three questions are unanswerable, so
        // this has to be checked first no matter what the counts say.
        XCTAssertEqual(ArtifactsEmptyReason.resolve(
            hasSession: false, hasTranscript: false, artifactCount: 0, visibleCount: 0),
            .noSessionBound)
    }

    func testSessionBoundButTranscriptNotYetOnDisk() {
        // The exact case that exposed this: Opus spawned a pane, nobody typed
        // in it, so Claude never wrote a transcript for that session id.
        XCTAssertEqual(ArtifactsEmptyReason.resolve(
            hasSession: true, hasTranscript: false, artifactCount: 0, visibleCount: 0),
            .transcriptNotStarted)
    }

    func testTranscriptExistsButProducedNothing() {
        XCTAssertEqual(ArtifactsEmptyReason.resolve(
            hasSession: true, hasTranscript: true, artifactCount: 0, visibleCount: 0),
            .sessionHasNoArtifacts)
    }

    func testArtifactsExistButTheFilterHidesThemAll() {
        XCTAssertEqual(ArtifactsEmptyReason.resolve(
            hasSession: true, hasTranscript: true, artifactCount: 9, visibleCount: 0),
            .filterExcludesAll)
    }

    func testEveryReasonHasItsOwnMessage() {
        let messages = ArtifactsEmptyReason.allCases.map(\.message)
        XCTAssertEqual(Set(messages).count, messages.count,
                       "two reasons sharing a message is the bug this type exists to prevent")
    }

    func testMessagesAreEnglishAndFreeOfEmDash() {
        for reason in ArtifactsEmptyReason.allCases {
            XCTAssertFalse(reason.message.isEmpty)
            XCTAssertFalse(reason.message.contains("\u{2014}"), "em dash in a UI string")
        }
    }

    func testTheOriginalMessageSurvivesForTheCaseItDescribedCorrectly() {
        // Regression guard: the one situation the old single message did
        // describe correctly must keep describing it.
        XCTAssertEqual(ArtifactsEmptyReason.sessionHasNoArtifacts.message,
                       "No artifacts in this session")
    }
}
