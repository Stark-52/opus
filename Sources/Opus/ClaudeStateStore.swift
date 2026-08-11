// ClaudeStateStore — the live "what is each Claude session doing right now"
// map, driven entirely by the .opusClaudeEvent hook bus (Task 1: see
// EventSocketServer.swift). TerminalContainerView reads this to paint the
// tab-bar activity dot for each tab and to decide when a background/
// invisible session should raise a native notification via ClaudeAttention.
//
// Threading: EventSocketServer posts .opusClaudeEvent exclusively via
// DispatchQueue.main.async (see EventSocketServer.handleClient), so every
// event this store's observer receives already arrives on the main thread.
// The rest of the public API (state(forSessionId:), markSeen(sessionId:))
// is likewise only ever called from AppKit code (TerminalContainerView),
// itself main-thread-only. There is therefore no locking in this class —
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

    private var activity: [String: PaneActivity] = [:]

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

    @objc private func claudeEventReceived(_ note: Notification) {
        assert(Thread.isMainThread, "ClaudeStateStore is main-thread only")
        guard let event = note.userInfo?["event"] as? OpusClaudeEvent else { return }
        let current = activity[event.sessionId] ?? .idle
        set(Self.nextActivity(current: current, event: event.kind), forSessionId: event.sessionId)
    }

    private func set(_ next: PaneActivity, forSessionId sessionId: String) {
        guard activity[sessionId] != next else { return }   // no-op change never fires a repaint
        activity[sessionId] = next
        NotificationCenter.default.post(name: .opusPaneActivityChanged, object: nil)
    }
}
