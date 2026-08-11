import XCTest
@testable import Opus

/// ClaudeStateStore.shared is a singleton with an internal dictionary that
/// persists for the whole test-process lifetime, so every test below uses a
/// fresh UUID-suffixed sessionId to avoid cross-test contamination — there's
/// no reset API (and none is needed in production: sessionIds are unique per
/// claude process).
///
/// setUp() forces `ClaudeStateStore.shared` into existence before each test
/// so its `.opusClaudeEvent` observer is guaranteed registered before this
/// test's own `post(...)` calls — mirrors the same eager-init reasoning
/// documented on the `_ = ClaudeStateStore.shared` line in
/// AppDelegate.applicationDidFinishLaunching.
final class ClaudeStateStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = ClaudeStateStore.shared
    }

    private func post(_ event: OpusClaudeEvent) {
        NotificationCenter.default.post(name: .opusClaudeEvent, object: nil, userInfo: ["event": event])
    }

    private func makeSessionId() -> String { "sess-\(UUID().uuidString)" }

    // MARK: nextActivity — pure transition table, exhaustive over kind × current

    func testWorkingKindsAlwaysGoToWorkingRegardlessOfCurrent() {
        let workingKinds: [OpusClaudeEvent.Kind] = [.promptSubmitted, .toolUse(name: "Bash"), .toolDone]
        for kind in workingKinds {
            for current: PaneActivity in [.idle, .working, .needsInput, .done] {
                XCTAssertEqual(ClaudeStateStore.nextActivity(current: current, event: kind), .working,
                                "kind=\(kind) current=\(current)")
            }
        }
    }

    func testTurnEndedAlwaysGoesToDoneRegardlessOfCurrent() {
        for current: PaneActivity in [.idle, .working, .needsInput, .done] {
            XCTAssertEqual(ClaudeStateStore.nextActivity(current: current, event: .turnEnded), .done)
        }
    }

    func testSessionStartedAlwaysGoesToIdleRegardlessOfCurrent() {
        for current: PaneActivity in [.idle, .working, .needsInput, .done] {
            XCTAssertEqual(ClaudeStateStore.nextActivity(current: current, event: .sessionStarted(source: "startup")), .idle)
        }
    }

    func testNeedsAttentionInputKindsMapToNeedsInputRegardlessOfCurrent() {
        let inputKinds = ["permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog"]
        for kind in inputKinds {
            for current: PaneActivity in [.idle, .working, .needsInput, .done] {
                XCTAssertEqual(
                    ClaudeStateStore.nextActivity(current: current, event: .needsAttention(kind: kind, message: "")),
                    .needsInput, "kind=\(kind) current=\(current)")
            }
        }
    }

    func testNeedsAttentionAgentCompletedAlwaysGoesToDoneRegardlessOfCurrent() {
        for current: PaneActivity in [.idle, .working, .needsInput, .done] {
            XCTAssertEqual(
                ClaudeStateStore.nextActivity(current: current, event: .needsAttention(kind: "agent_completed", message: "")),
                .done)
        }
    }

    func testNeedsAttentionAuthSuccessAndUnknownKindsKeepCurrent() {
        for kind in ["auth_success", "some_future_notification_type"] {
            for current: PaneActivity in [.idle, .working, .needsInput, .done] {
                XCTAssertEqual(
                    ClaudeStateStore.nextActivity(current: current, event: .needsAttention(kind: kind, message: "")),
                    current, "kind=\(kind) current=\(current)")
            }
        }
    }

    // MARK: Store — event-driven updates via real NotificationCenter posts

    func testStoreDefaultsToIdleForAnUnknownSession() {
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: makeSessionId()), .idle)
    }

    func testStoreUpdatesStateWhenAnEventArrives() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .promptSubmitted))
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .working)
    }

    func testStoreTracksASequenceOfEventsToDone() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .promptSubmitted))
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .toolUse(name: "Bash")))
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .toolDone))
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .turnEnded))
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .done)
    }

    func testStoreKeepsSessionsIndependent() {
        let a = makeSessionId()
        let b = makeSessionId()
        post(OpusClaudeEvent(sessionId: a, cwd: "/tmp", kind: .turnEnded))
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: a), .done)
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: b), .idle)
    }

    // MARK: markSeen semantics

    func testMarkSeenClearsDoneToIdle() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .turnEnded))
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .done)
        ClaudeStateStore.shared.markSeen(sessionId: sessionId)
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .idle)
    }

    func testMarkSeenClearsNeedsInputToIdle() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .needsAttention(kind: "permission_prompt", message: "")))
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .needsInput)
        ClaudeStateStore.shared.markSeen(sessionId: sessionId)
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .idle)
    }

    func testMarkSeenLeavesWorkingUntouched() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .promptSubmitted))
        ClaudeStateStore.shared.markSeen(sessionId: sessionId)
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .working)
    }

    func testMarkSeenOnAnUnknownSessionIsANoOp() {
        let sessionId = makeSessionId()
        ClaudeStateStore.shared.markSeen(sessionId: sessionId)   // must not crash or fabricate an entry
        XCTAssertEqual(ClaudeStateStore.shared.state(forSessionId: sessionId), .idle)
    }

    // MARK: .opusPaneActivityChanged — only posted on an actual change

    func testPaneActivityChangedIsPostedOnARealChange() {
        let sessionId = makeSessionId()
        let exp = expectation(forNotification: .opusPaneActivityChanged, object: nil, handler: nil)
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .promptSubmitted))
        wait(for: [exp], timeout: 1)
    }

    func testPaneActivityChangedIsNotPostedWhenStateDoesNotChange() {
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .promptSubmitted))   // idle → working

        let exp = expectation(forNotification: .opusPaneActivityChanged, object: nil, handler: nil)
        exp.isInverted = true
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .toolUse(name: "Bash")))   // working → working
        wait(for: [exp], timeout: 0.3)
    }
}
