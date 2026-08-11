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

    // MARK: Pane ↔ Claude session association (Lot 3, Task 2 heuristic v1,
    // superseded as the PRIMARY path by Task 6's deterministic ids)
    //
    // Task 6: Opus now knows almost every spawn's session id up front — it
    // either mints the UUID itself (`--session-id`) or was told the exact id
    // to resume — and binds a pane directly via `bindSession` the moment
    // that's true (`FilteredClaudeTab` right after `pane.start()`;
    // `TerminalContainerView.sharedBackendDidSpawn` for the shared pane, fed
    // by `ClaudeBackend.currentSessionId` via the `.claudeBackendDidSpawn`
    // notification's `sessionId` userInfo). The SPAWN-ORDER heuristic
    // documented below is now a FALLBACK, exercised only when a spawn's id
    // is genuinely unknown at spawn time — today that's exactly one case:
    // a `.continueMostRecent` (`claude --continue`) launch, where claude
    // itself picks the id, not Opus. Every pane spawn still registers a
    // `registerPendingSpawn` entry regardless (defense in depth, and needed
    // for that one fallback case), but a directly-bound pane's own
    // SessionStart hook arriving later just finds its entry already
    // resolved — see `bindOldestPendingSpawn`'s guards.
    //
    // Original heuristic (still the fallback's mechanics): a pane is
    // associated with the session_id its first SessionStart hook reports, by
    // SPAWN ORDER: every pane spawn (across every TerminalContainerView —
    // see `registerPendingSpawn`) records a pending (paneToken, timestamp)
    // entry, and the oldest entry still younger than `pendingSpawnWindow` is
    // popped and bound the moment a SessionStart event arrives.
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
    // KNOWN RACE, NOW EFFECTIVELY CLOSED IN PRACTICE (was "accepted for v1"):
    // the pre-Task-6 concern was two spawns' SessionStart hooks arriving out
    // of spawn order (e.g. a slow cold `claude` start racing a fast warm
    // one) and the heuristic binding the wrong sessionId to the wrong pane.
    // Direct binding removes every spawn from this race EXCEPT
    // `.continueMostRecent` ones, and only `ClaudeBackend.shared` — a single
    // process-wide singleton — ever spawns with that mode (private tabs
    // never do, see `FilteredClaudeTab.start`), so there is at most ONE
    // genuinely-unresolved FIFO entry in flight at a time in normal usage —
    // nothing left for it to race against. Still documented rather than
    // deleted: the fallback code path itself is unchanged and would
    // reintroduce the same race if a future caller ever spawned a second
    // concurrent `.continueMostRecent` session.
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
    /// `bindOldestPendingSpawn`) OR it was bound directly at spawn time (see
    /// `bindSession`). `nil` for a pane that hasn't spawned, is still
    /// waiting on its SessionStart, or was never registered at all.
    func sessionId(forPaneToken paneToken: ObjectIdentifier) -> String? {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        return paneSessionIds[paneToken]
    }

    /// Direct, immediate pane↔session binding (Lot 3, Task 6) — used whenever
    /// the caller KNOWS the id up front instead of waiting for a SessionStart
    /// hook to report it: `FilteredClaudeTab`'s minted id (private tabs,
    /// right after `pane.start()`) and the shared backend's known-id spawns
    /// (via `.claudeBackendDidSpawn`'s `sessionId` userInfo — see
    /// `TerminalContainerView.sharedBackendDidSpawn`). A plain dictionary
    /// write, so re-binding an already-bound token to a DIFFERENT id (e.g.
    /// `FilteredClaudeTab.restartFresh()` minting a new id for the same pane)
    /// simply overwrites — there is no stale-value guard here, unlike
    /// `bindOldestPendingSpawn` below, because the caller is asserting a
    /// fact it already knows for certain, not racing a heuristic.
    func bindSession(paneToken: ObjectIdentifier, sessionId: String) {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        paneSessionIds[paneToken] = sessionId
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
    ///
    /// Lot 3, Task 6: this is now the FALLBACK path, used only when a spawn's
    /// id was genuinely unknown at spawn time (a `.continueMostRecent`
    /// launch — see `ClaudeBackend.currentSessionId`'s doc comment). Every
    /// other spawn site binds directly via `bindSession` instead, which can
    /// leave a now-redundant entry sitting in `pendingSpawns` (registered by
    /// `registerPendingSpawn` before the direct bind resolved it, or before
    /// today's rewrite this queue was the ONLY path — see Fix round 1
    /// comments above). Two guards keep those leftovers from corrupting a
    /// genuinely-unmatched spawn's binding:
    ///   1. If `sessionId` itself is already a value in `paneSessionIds`,
    ///      this SessionStart event is simply the REAL hook firing for a
    ///      pane we already know about directly — the FIFO doesn't need
    ///      touching at all, so bail before scanning it. (Without this, an
    ///      already-bound pane's own hook could steal an OLDER, still
    ///      genuinely-unresolved entry belonging to a different pane and
    ///      bind it to the wrong session.)
    ///   2. While scanning for a spawn to bind, pop-and-discard (not bind)
    ///      any entry whose token is ALREADY a key in `paneSessionIds` —
    ///      stale queue cruft from a pane that got a direct bind before its
    ///      own hook arrived — and keep looking for the first genuinely
    ///      unbound entry.
    private func bindOldestPendingSpawn(toSessionId sessionId: String) {
        guard !paneSessionIds.values.contains(sessionId) else { return }
        let cutoff = now().addingTimeInterval(-Self.pendingSpawnWindow)
        pendingSpawns.removeAll { $0.at < cutoff }
        while !pendingSpawns.isEmpty {
            let spawn = pendingSpawns.removeFirst()
            if paneSessionIds[spawn.paneToken] != nil { continue }   // already bound elsewhere — discard, keep scanning
            paneSessionIds[spawn.paneToken] = sessionId
            return
        }
    }

    private func set(_ next: PaneActivity, forSessionId sessionId: String) {
        guard activity[sessionId] != next else { return }   // no-op change never fires a repaint
        activity[sessionId] = next
        NotificationCenter.default.post(name: .opusPaneActivityChanged, object: nil)
    }
}
