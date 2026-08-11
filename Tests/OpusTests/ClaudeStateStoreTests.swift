import XCTest
@testable import Opus

/// Dummy stand-in for a pane's `TerminalView` identity — the store only ever
/// deals in `ObjectIdentifier`s, so any class instance works as a synthetic
/// "pane token" without pulling AppKit/TerminalView into this test target.
/// Never instantiated directly by tests — see `ClaudeStateStoreTests.makeToken()`,
/// which is the only thing that creates one (and permanently retains it).
private final class DummyPaneToken {}

/// ClaudeStateStore.shared is a singleton with internal state that persists
/// for the whole test-process lifetime, so every test below uses a fresh
/// UUID-suffixed sessionId (via `makeSessionId()`) to avoid cross-test
/// contamination on the `activity` dictionary — there's no reset API (and
/// none is needed in production: sessionIds are unique per claude process).
/// The `pendingSpawns`/`paneSessionIds` registry (Fix round 1) has the same
/// no-reset property; tests that touch it fully drain what they register
/// (see the "Fix round 1" section below) so they don't depend on running in
/// any particular order relative to each other.
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

    override func tearDown() {
        // `now` is an injectable singleton hook (see testStalePendingSpawn...
        // below) — restore it so a later test doesn't inherit a frozen clock.
        ClaudeStateStore.shared.now = Date.init
        super.tearDown()
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

    // MARK: Fix round 1 — global pane↔session binding registry
    //
    // `makeToken()` permanently retains its `DummyPaneToken` into
    // `keepAliveTokens` for the rest of the process's lifetime instead of
    // letting it go out of scope at the end of its test. This turned out to
    // matter in practice, not just in theory: an earlier version of these
    // tests handed off bare `ObjectIdentifier`s from short-lived per-test
    // locals, and hit real, reproducible failures — once a token from an
    // earlier test was deallocated, the allocator readily reused its
    // address for a token created in a LATER test, making two "different"
    // synthetic tokens compare equal. Exactly the address-reuse risk
    // documented on `ClaudeStateStore.paneSessionIds`, just triggered far
    // more easily here (many identical-size allocations in quick
    // succession) than the narrow real-world scenario it describes.
    private static var keepAliveTokens: [DummyPaneToken] = []

    private func makeToken() -> ObjectIdentifier {
        let token = DummyPaneToken()
        Self.keepAliveTokens.append(token)
        return ObjectIdentifier(token)
    }

    func testSessionStartedBindsTheOldestPendingSpawnFirst() {
        let tokenA = makeToken()
        let tokenB = makeToken()
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: tokenA)
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: tokenB)

        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .sessionStarted(source: "startup")))

        XCTAssertEqual(ClaudeStateStore.shared.sessionId(forPaneToken: tokenA), sessionId)
        XCTAssertNil(ClaudeStateStore.shared.sessionId(forPaneToken: tokenB))

        // Drain tokenB too — the store's pendingSpawns queue is a shared
        // singleton with no reset hook, so leaving it pending here would let
        // a LATER test's own sessionStarted post accidentally consume it
        // instead of that test's own token.
        post(OpusClaudeEvent(sessionId: makeSessionId(), cwd: "/tmp", kind: .sessionStarted(source: "startup")))
        XCTAssertNotNil(ClaudeStateStore.shared.sessionId(forPaneToken: tokenB))
    }

    func testSecondSessionStartedBindsTheNextPendingSpawn() {
        let tokenA = makeToken()
        let tokenB = makeToken()
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: tokenA)
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: tokenB)

        let sessionA = makeSessionId()
        let sessionB = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionA, cwd: "/tmp", kind: .sessionStarted(source: "startup")))
        post(OpusClaudeEvent(sessionId: sessionB, cwd: "/tmp", kind: .sessionStarted(source: "startup")))

        XCTAssertEqual(ClaudeStateStore.shared.sessionId(forPaneToken: tokenA), sessionA)
        XCTAssertEqual(ClaudeStateStore.shared.sessionId(forPaneToken: tokenB), sessionB)
    }

    func testStalePendingSpawnIsPrunedAndNeverBound() {
        let tokenA = makeToken()
        let base = Date()
        ClaudeStateStore.shared.now = { base }
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: tokenA)

        // Advance the injected clock past the 8s pendingSpawnWindow before the
        // SessionStart arrives — no real sleeping required.
        ClaudeStateStore.shared.now = { base.addingTimeInterval(9) }
        let sessionId = makeSessionId()
        post(OpusClaudeEvent(sessionId: sessionId, cwd: "/tmp", kind: .sessionStarted(source: "startup")))

        XCTAssertNil(ClaudeStateStore.shared.sessionId(forPaneToken: tokenA))
    }

    func testSessionIdForPaneTokenIsNilForAnUnregisteredToken() {
        XCTAssertNil(ClaudeStateStore.shared.sessionId(forPaneToken: makeToken()))
    }
}
