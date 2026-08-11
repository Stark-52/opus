// ClaudeStateStore — the live "what is each Claude session doing right now"
// map, driven entirely by the .opusClaudeEvent hook bus (Task 1: see
// EventSocketServer.swift). TerminalContainerView reads this to paint the
// tab-bar activity dot for each tab and to decide when a background/
// invisible session should raise a native notification via ClaudeAttention.
// It also owns the pane↔session spawn-order binding (Fix round 1) — see the
// doc comment on `paneSessionIds` below for why that lives here and not per
// TerminalContainerView.
//
// Threading: EventSocketServer posts .opusClaudeEvent exclusively via
// DispatchQueue.main.async (see EventSocketServer.handleClient), so every
// event this store's observer receives already arrives on the main thread.
// The rest of the public API (state(forSessionId:), markSeen(sessionId:),
// registerPendingSpawn(paneToken:), sessionId(forPaneToken:)) is likewise
// only ever called from AppKit code (TerminalContainerView), itself
// main-thread-only. There is therefore no locking in this class —
// main-thread-only access is asserted below, not merely assumed. AppDelegate
// forces `ClaudeStateStore.shared` to exist (registering its observer)
// before any surface that could spawn a claude process is constructed — see
// the `_ = ClaudeStateStore.shared` line in applicationDidFinishLaunching —
// so there's no race where an early hook event arrives before anyone is
// listening.

import Foundation

/// What a single Claude session is doing right now, as far as the hook
/// stream can tell. Drives the tab-bar dot color (see OpusTabBar.draw).
enum PaneActivity: Equatable {
    case idle        // no dot
    case working     // amber dot — prompt in flight / tool running
    case needsInput  // red dot — permission/idle/elicitation/agent_needs_input
    case done        // green dot — turn ended, or agent reported completion
}

/// Posted on the main queue whenever ANY session's PaneActivity actually
/// changes (from a fresh hook event, or from markSeen). No userInfo —
/// observers just re-read whatever session(s) they care about via
/// `ClaudeStateStore.shared.state(forSessionId:)`.
extension Notification.Name {
    static let opusPaneActivityChanged = Notification.Name("com.stark52.opus.paneActivityChanged")
}

final class ClaudeStateStore {
    static let shared = ClaudeStateStore()

    /// How long a pane's spawn stays eligible to claim the next SessionStart
    /// hook before it's pruned as abandoned (its hook was lost, or the spawn
    /// itself failed) — see `bindOldestPendingSpawn`. 8 seconds gives a cold
    /// `claude` launch (disk cache miss, first run after an update, etc.)
    /// comfortable headroom.
    ///
    /// Provenance note: the original task-2-brief.md draft quoted 5s for
    /// this window; the authoritative controller interface spec that
    /// superseded it (and is what actually shipped, here and in the Fix
    /// round 1 review that asked this be called out explicitly) said 8s.
    /// There was no code drift — every revision of the implementation has
    /// used 8s — just an inconsistency between the draft brief and the spec
    /// it was refined into. 8s is the deliberate, accepted final value.
    private static let pendingSpawnWindow: TimeInterval = 8

    private var activity: [String: PaneActivity] = [:]

    // MARK: Pane ↔ Claude session association (Lot 3, Task 2 — heuristic v1)
    //
    // There's no deterministic session id threaded through at spawn time yet
    // (that's Task 6: mint --session-id ourselves and pass it straight
    // through). Until then a pane is associated with the session_id its
    // first SessionStart hook reports, by SPAWN ORDER: every pane spawn
    // (across every TerminalContainerView — see `registerPendingSpawn`)
    // records a pending (paneToken, timestamp) entry, and the oldest entry
    // still younger than `pendingSpawnWindow` is popped and bound the moment
    // a SessionStart event arrives.
    //
    // GLOBAL, not per-container (Fix round 1): this used to be two separate
    // dictionaries, one per TerminalContainerView instance (the panel's and
    // MainTerminalWindow's). Both containers observe the same global
    // .opusClaudeEvent broadcast, so with two independent FIFOs, one
    // container's sessionStarted handler could pop and consume a
    // SessionStart hook that actually belonged to a pane spawned in the
    // OTHER container. The robbed pane's own pending entry then sat in its
    // container's queue forever with no SessionStart left to claim it —
    // permanently `.idle`, no dot, no recovery, and completely silent. An
    // `ObjectIdentifier` of a pane's `TerminalView` is unique across the
    // whole process regardless of which container owns the pane, so a
    // SINGLE FIFO here (shared by every container) removes that entire
    // starvation class: every SessionStart is matched against the one true
    // spawn order, full stop.
    //
    // KNOWN RACE (accepted for v1, narrower than the bug above): two spawns
    // — in the same container or different ones — landing within the same
    // sub-second window can still have their SessionStart hooks arrive out
    // of spawn order (e.g. a slow cold `claude` start racing a fast warm
    // one), and the heuristic would then bind the wrong sessionId to the
    // wrong pane. This is cosmetic (wrong dot on one of the two panes),
    // never a starvation/never-recovers bug like the one above — every
    // pending spawn still eventually gets SOME SessionStart bound to it (or
    // ages out cleanly). Task 6's deterministic id removes this heuristic
    // (and this residual race) entirely.
    //
    // Keyed by the pane's TerminalView identity (ObjectIdentifier), same
    // pattern already used by `TerminalContainerView.deadOverlays`. Entries
    // for panes that have since closed are never removed — see
    // TerminalContainerView's own doc comment near its pane-lookup call
    // sites for why that's accepted as harmless-enough for v1.
    private var paneSessionIds: [ObjectIdentifier: String] = [:]
    private var pendingSpawns: [(paneToken: ObjectIdentifier, at: Date)] = []

    /// Injectable clock. Production always reads the real `Date()`; tests
    /// override this to advance "now" past `pendingSpawnWindow` without
    /// sleeping for 8 real seconds — same injectable-closure pattern
    /// already used by `ClaudeAttention.isUserLookingAtOpus`/`postSystemSignals`.
    var now: () -> Date = Date.init

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(claudeEventReceived(_:)),
            name: .opusClaudeEvent, object: nil
        )
    }

    /// Pure transition table — no store state, no I/O. This is the entire
    /// decision logic and is exhaustively unit tested; the store's own event
    /// handling below is a one-line call into it, and
    /// TerminalContainerView's notification-precision check (Step 4) reuses
    /// it too instead of re-deriving the same rules a second time.
    static func nextActivity(current: PaneActivity, event kind: OpusClaudeEvent.Kind) -> PaneActivity {
        switch kind {
        case .promptSubmitted, .toolUse, .toolDone:
            return .working
        case .needsAttention(let attentionKind, _):
            switch attentionKind {
            case "permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog":
                return .needsInput
            case "agent_completed":
                return .done
            default:
                // auth_success, plus any future/unrecognized Notification
                // type — nothing actionable happened, leave the dot alone.
                return current
            }
        case .turnEnded:
            return .done
        case .sessionStarted:
            return .idle
        }
    }

    /// Current activity for a session that hasn't produced any event yet
    /// defaults to `.idle` — matches a freshly-spawned, not-yet-bound pane.
    func state(forSessionId sessionId: String) -> PaneActivity {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        return activity[sessionId] ?? .idle
    }

    /// The user switched to (or otherwise looked at) this session's tab — a
    /// `.done`/`.needsInput` dot has now been "read" and clears back to
    /// idle. `.working` and `.idle` are left untouched: a still-running turn
    /// doesn't silently look finished just because the user glanced at it,
    /// and there's nothing to clear on an already-idle session.
    func markSeen(sessionId: String) {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        guard let current = activity[sessionId], current == .done || current == .needsInput else { return }
        set(.idle, forSessionId: sessionId)
    }

    /// Called by a TerminalContainerView at every pane-spawn call site
    /// (bootstrapFirstTab's two branches, spawnNewTab, splitActivePane) —
    /// records that this pane is now awaiting its first SessionStart hook.
    func registerPendingSpawn(paneToken: ObjectIdentifier) {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        pendingSpawns.append((paneToken: paneToken, at: now()))
    }

    /// The sessionId currently bound to `paneToken`, if its SessionStart
    /// hook has already been matched (see `registerPendingSpawn` /
    /// `bindOldestPendingSpawn`). `nil` for a pane that hasn't spawned, is
    /// still waiting on its SessionStart, or was never registered at all.
    func sessionId(forPaneToken paneToken: ObjectIdentifier) -> String? {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        return paneSessionIds[paneToken]
    }

    @objc private func claudeEventReceived(_ note: Notification) {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        guard let event = note.userInfo?["event"] as? OpusClaudeEvent else { return }
        if case .sessionStarted = event.kind {
            bindOldestPendingSpawn(toSessionId: event.sessionId)
        }
        let current = activity[event.sessionId] ?? .idle
        set(Self.nextActivity(current: current, event: event.kind), forSessionId: event.sessionId)
    }

    /// Pops the oldest still-fresh (< pendingSpawnWindow) pending spawn and
    /// binds it to `sessionId`. Also prunes anything that aged out without
    /// ever getting a match — a lost/never-arriving hook shouldn't
    /// accumulate in the queue forever.
    private func bindOldestPendingSpawn(toSessionId sessionId: String) {
        let cutoff = now().addingTimeInterval(-Self.pendingSpawnWindow)
        pendingSpawns.removeAll { $0.at < cutoff }
        guard !pendingSpawns.isEmpty else { return }
        let spawn = pendingSpawns.removeFirst()
        paneSessionIds[spawn.paneToken] = sessionId
    }

    private func set(_ next: PaneActivity, forSessionId sessionId: String) {
        guard activity[sessionId] != next else { return }   // no-op change never fires a repaint
        activity[sessionId] = next
        NotificationCenter.default.post(name: .opusPaneActivityChanged, object: nil)
    }
}
