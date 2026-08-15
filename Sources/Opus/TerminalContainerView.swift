// TerminalContainerView — owns the tabs/panes/splits and the bottom OpusTabBar.
// Hosts (QuickTerminalPanel, MainTerminalWindow) embed this view and forward
// key events / window callbacks via the TerminalContainerHost protocol.
//
// Task 12: new class introduced, NOT yet used by QuickTerminalPanel.
// Task 13: QuickTerminalPanel swaps its inline state for an embedded instance.
// Task 14: MainTerminalWindow embeds it too.

import AppKit
import SwiftTerm
import Darwin
import OpusArtifactsKit

protocol TerminalContainerHost: AnyObject {
    var hostWindow: NSWindow? { get }
    /// Called when the user wants to spawn a Terminal.app mirror of the
    /// shared session. Host may no-op (Standalone pairing, MainTerminalWindow).
    func openInTerminalRequested()
}

final class TerminalContainerView: NSView, TerminalViewDelegate {
    weak var host: TerminalContainerHost?

    private var terminalArea: NSView!
    private var tabBar: OpusTabBar!
    private var tabBarHeightConstraint: NSLayoutConstraint!
    private var terminalAreaBottomConstraint: NSLayoutConstraint!
    private var shieldButton: NSButton?
    /// Bottom status rail (visual-harmonization spec, section 1 "Rail de
    /// statut") — replaces the old top-right PaneActivityDot + "ctx NN%"
    /// label pair (v1.4.1/v1.4.2) AND the bottom ContextMeterBar strip. See
    /// buildSubviews' install site for the geometry, applyContextMeterResult
    /// for the context fraction/readout/tooltip wiring, and
    /// refreshTabBarStates for the activity-dot wiring.
    private var statusRail: StatusRailView!
    /// Own bottom constraint to the container's bottomAnchor, switched in
    /// updateTabIndicator alongside tabBarHeightConstraint/
    /// terminalAreaBottomConstraint — same mechanism the old
    /// contextMeterBottomConstraint used (see updateTabIndicator's doc
    /// comment for why this can't just track tabBar.topAnchor).
    private var railBottomConstraint: NSLayoutConstraint!
    /// The "NNk / NNk tokens (NN%)" half of the rail's tooltip, from the most
    /// recent context-meter scan — `nil` when there's no context data to show
    /// (the two `applyContextMeterResult`/`refreshContextMeter` nil branches,
    /// where the rail's fill is invisible too). Kept separately from
    /// `statusRail.tooltipText` so `refreshTabBarStates` — which fires on
    /// every activity change, independent of the context-meter timer — can
    /// recompose the full tooltip from this plus the current activity
    /// without redoing the context math. See `updateStatusRailTooltip`.
    private var contextTooltipSentence: String?
    private var findBar: FindBarView?
    private var lastSearchTerm = ""

    // Cockpit (Lot 3, Task 4) — context-window burn meter, see the MARK
    // section near the bottom of this file for the timer/read/parse pipeline.
    private var contextMeterTimer: Timer?
    /// Bumped on every `refreshContextMeter()` call — see that function's
    /// doc comment for the staleness guard this enables.
    private var contextMeterGeneration = 0

    // v1.6 backlog Task 3 — Cmd+Shift+T todo drawer. See the MARK section
    // near `toggleTodoDrawer()` below for the full timer/refresh pipeline —
    // deliberately the SAME shape as the context meter directly above
    // (background read, generation-guarded main-thread apply, timer that
    // only runs while the surface is actually visible), not a new pattern.
    private var todoDrawer: TodoDrawerView!
    /// Owns the container's right edge: the terminal's trailing constraint,
    /// the top-right button row's shift, and (via `onChange`) the Tasks
    /// timer's lifecycle. Optional, not implicitly unwrapped: `installShieldButton()`
    /// (called from `init`, after `buildSubviews()`) reads it through
    /// `pinToTopRightRow`, and although that call order is safe today, a
    /// force unwrap would turn any future earlier call into a launch crash
    /// instead of a harmlessly closed drawer. Read as `rightDock?.occupant
    /// ?? .none` everywhere.
    private var rightDock: RightDock?
    /// Own trailing constraint on `terminalArea` — `0` when the drawer is
    /// closed, `-TodoDrawerView.width` when open, so the terminal never
    /// draws underneath the drawer. See `toggleTodoDrawer()`.
    private var terminalAreaTrailingConstraint: NSLayoutConstraint!
    /// Own bottom constraint on the drawer, switched in `updateTabIndicator`
    /// alongside `terminalAreaBottomConstraint`/`railBottomConstraint` — the
    /// drawer's bottom edge tracks EXACTLY the same y-position as
    /// `terminalArea`'s own bottom edge (same constants, same lockstep
    /// switch), so it always ends strictly above the status rail / tab bar
    /// band without any drawer-specific magic numbers. See
    /// `buildSubviews()`'s installation site and task-3-report.md for the
    /// arithmetic this guarantees.
    private var todoDrawerBottomConstraint: NSLayoutConstraint!
    /// Artifacts drawer (Lot artifacts-drawer, Task 8) — second occupant of
    /// the right dock, same top/trailing/width/bottom treatment as
    /// `todoDrawer`/`todoDrawerBottomConstraint` above. See `buildSubviews`'
    /// installation site.
    private var artifactsDrawer: ArtifactsDrawerView!
    private var artifactsDrawerBottomConstraint: NSLayoutConstraint!
    private var todoDrawerTimer: Timer?
    /// Bumped on every `refreshTodoDrawer()` call — same staleness guard as
    /// `contextMeterGeneration` above; see `refreshTodoDrawer`'s doc comment.
    private var todoDrawerGeneration = 0
    /// Fix round finding F3: `refreshTodoDrawer()` fires on EVERY
    /// `.opusPaneActivityChanged` post (prompt submitted, each tool
    /// start/stop) via `paneActivityChanged` below, not just the 5s timer —
    /// a tool-use burst can post several of those in quick succession. The
    /// generation counter above already drops a STALE *result*, but it does
    /// nothing about the *work*: each event still pays for its own
    /// `contentsOfDirectory` + N file reads + N decodes before that result
    /// is thrown away. This flag stops a new background read from being
    /// kicked off at all while one is already in flight, so overlapping
    /// refreshes don't stack up during a burst — set true right before
    /// dispatching, cleared back on main once that read's result (used or
    /// dropped) has been handled.
    private var todoDrawerRefreshInFlight = false
    private static let tasksDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/tasks")

    // Artifacts drawer (Lot artifacts-drawer, Task 9) — same shape as the
    // todo drawer's timer/generation/in-flight trio directly above.
    private var artifactsTimer: Timer?
    private var artifactsGeneration = 0
    private var artifactsRefreshInFlight = false
    /// Byte offset into the current session's transcript. Reset whenever the
    /// bound session changes, so a tab switch cannot resume a new file from
    /// the old file's offset.
    private var artifactsOffset: UInt64 = 0
    private var artifactsSessionId: String?

    /// Trailing offsets — all measured from `terminalArea.trailingAnchor` —
    /// of the buttons that share the panel's top-right row: the shield
    /// (installed by this container) plus, in the Quick Terminal panel, the
    /// pin and "open in Terminal" (↗) buttons, which are subviews of the
    /// panel's blur view one level up and get pinned into the row via
    /// `pinToTopRightRow`.
    ///
    /// The row has to slide left with the terminal area when the todo drawer
    /// opens. Fix round finding F2 did that for the shield alone by moving
    /// its anchor from the container's trailing edge to `terminalArea`'s —
    /// which left its row siblings behind, still pinned to the container,
    /// visibly floating inside the drawer's own top-right corner as if they
    /// belonged to the drawer (observed on screen in v1.6). Pinning every
    /// button in the row to that SAME moving anchor is what makes the row
    /// travel as one unit.
    ///
    /// `drawerOpenShift` covers the one button that does not fit that rule
    /// on its own: the row's rightmost (↗) sits 4pt PAST the terminal area's
    /// trailing edge, inside the panel's 14pt blur padding, where there is
    /// nothing to collide with. With the drawer open that same +4 would land
    /// on the drawer's leading edge (the drawer begins exactly where
    /// `terminalArea` now ends — see buildSubviews). So while the drawer is
    /// open the whole row shifts a further 8pt left, which puts the
    /// rightmost button 4pt INSIDE the shrunken terminal area and preserves
    /// every gap between buttons. Closed, the shift is 0 and every button
    /// sits at exactly the pixel it always did.
    enum TopRightButtonRow {
        /// "Open in Terminal" (↗) — the row's rightmost button. +4 reproduces
        /// its historical `blur.trailingAnchor - 10` pin: the container's
        /// trailing edge is `blur.trailing - 14`.
        static let openBase: CGFloat = 4
        /// Dangerous-mode shield — unchanged from finding F2.
        static let shieldBase: CGFloat = -28
        /// Pin (autohide toggle) — the row's leftmost button. -58 reproduces
        /// its historical `blur.trailingAnchor - 72` pin.
        static let pinBase: CGFloat = -58
        /// Extra leftward travel applied to the WHOLE row while the drawer is
        /// open, so the rightmost button clears the drawer's leading edge.
        static let drawerOpenShift: CGFloat = -8

        static func trailingConstant(base: CGFloat, drawerOpen: Bool) -> CGFloat {
            base + (drawerOpen ? drawerOpenShift : 0)
        }
    }

    /// (constraint, base offset) for every button pinned into the top-right
    /// row. Recomputed as a SET on every drawer toggle — the v1.6 bug was
    /// exactly a row whose members moved independently.
    private var topRightRowConstraints: [(constraint: NSLayoutConstraint, base: CGFloat)] = []

    // Cockpit (Lot 3, Task 5) — Cmd+click file[:line] references. The
    // returned monitor token must be retained (AppKit invalidates/drops an
    // unretained one), same as MainTerminalWindow.keyMonitor. Never removed
    // — see the class-level doc comment above: a TerminalContainerView
    // lives for the app's lifetime, same as every NotificationCenter
    // observer registered in init below.
    private var commandClickMonitor: Any?

    // Cockpit (Lot 3, Task 7) — broadcast input to every pane of the ACTIVE
    // tab. See the MARK section near `broadcast(data:)` below for the full
    // routing/arming story.
    /// When armed, every keystroke typed into any pane of the ACTIVE tab is
    /// written to EVERY pane of that tab, not just the one the user is
    /// looking at. Always scoped to whichever tab was active at arm time —
    /// switching tabs, closing a pane, or splitting all disarm first (see
    /// `switchTab`/`closePane`/`splitActivePane`), so `broadcastArmed ==
    /// true` is an invariant that always means "the CURRENT active tab's
    /// panes are bordered and receiving broadcast input," never a stale tab
    /// left over from before a switch.
    private(set) var broadcastArmed = false { didSet { refreshBroadcastBorders() } }

    /// Icy-cyan brand color — same token as `OpusSplitView.dividerColor` —
    /// at a much louder 0.8 alpha (the divider's own 0.30 is meant to be
    /// subtle; this needs to read as an unmistakable state change).
    private static let broadcastBorderColor = OpusTheme.cyan.withAlphaComponent(0.8).cgColor

    private var tabs: [NSView] = []
    private var tabPanes: [[TabPane]] = []
    private var tabActivePaneIndex: [Int] = []
    private var tabTitles: [String] = []
    private var activeTabIndex: Int = 0

    // Pane ↔ Claude session association (Lot 3, Task 2 — heuristic v1) used
    // to be tracked HERE, per-container. Fix round 1 (Task 2) moved it into
    // `ClaudeStateStore` as a single global registry shared by every
    // TerminalContainerView (panel and main window alike) — two independent
    // per-container FIFOs let one container silently steal a SessionStart
    // hook meant for a pane spawned in the OTHER container, leaving the
    // robbed pane permanently `.idle` with no recovery. See the doc comment
    // on `ClaudeStateStore.paneSessionIds`/`pendingSpawns` for the full
    // story (including the still-accepted, much narrower same-second-burst
    // race).
    //
    // Task 6 made binding DIRECT-FIRST: this container knows a private
    // pane's session id the instant it's minted, and binds it immediately
    // (`bindKnownSession`, called right after every `pane.start()`, and
    // again on every private-pane restart inside `FilteredClaudeTab.restart()`
    // itself — see that method) instead of waiting on a hook. The shared
    // pane's known id arrives via `sharedBackendDidSpawn`'s notification
    // userInfo. `recordPendingSpawn` + the SessionStart-hook FIFO
    // (`ClaudeStateStore.bindOldestPendingSpawn`) is now a FALLBACK,
    // exercised only when a spawn's id is genuinely unknown up front (a
    // `.continueMostRecent` shared-backend launch). Either way, this
    // container only holds thin glue: register/bind a pane at spawn time,
    // and look its bound session up via
    // `ClaudeStateStore.shared.sessionId(forPaneToken:)` wherever display
    // state or a notification decision needs it.

    /// True when this container is the tab-0 broadcast subscriber. Both the
    /// panel AND MainTerminalWindow pass `true` here (see MainTerminalWindow's
    /// setupContent) — tab 0 is shared across every Opus surface, Terminal.app
    /// mirroring included; there is no "fully private tab 0" mode anymore
    /// (that was true pre-v1.1, before the panelAndMain rework). `false` is
    /// unused by any current call site but kept as an escape hatch — the
    /// shield button / skip-permissions wiring below is still gated on it.
    private let useSharedTab0: Bool

    init(frame: NSRect, useSharedTab0: Bool) {
        self.useSharedTab0 = useSharedTab0
        super.init(frame: frame)
        wantsLayer = true
        buildSubviews()
        bootstrapFirstTab()
        // Fix round 2 (v1.4.1): sync the tab bar / context meter / terminal-
        // area constants to the real (single-tab) state right away.
        // updateTabIndicator() is otherwise only ever invoked by
        // switchTab(to:), which never runs for a session that starts and
        // stays on tab 0 — the app's PRIMARY usage mode — so without this
        // call the buildSubviews() defaults below would be the ONLY values
        // that ever apply for that entire session.
        updateTabIndicator()
        // Accept files dragged from Finder → insert their full path (like Terminal.app).
        registerForDraggedTypes([.fileURL])
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: .opusPreferencesDidChange, object: nil
        )
        // Cockpit (Lot 3, Task 2): every container (panel and main window
        // alike, regardless of useSharedTab0) tracks pane↔session binding
        // and reacts to activity changes so its own tab bar's dots stay
        // live. Not removed in a deinit — this class has none today, and in
        // practice a TerminalContainerView lives for the app's lifetime
        // (nativePanel / MainTerminalWindow.shared are effectively
        // singletons), same as every other observer registered in this init.
        NotificationCenter.default.addObserver(
            self, selector: #selector(claudeEventReceived(_:)),
            name: .opusClaudeEvent, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(paneActivityChanged),
            name: .opusPaneActivityChanged, object: nil
        )
        // Cockpit (Lot 3, Task 5): Cmd+leftMouseDown → try to open a
        // file[:line] reference under the click. A LOCAL monitor sees the
        // event before AppKit dispatches it into the responder chain, so
        // returning nil here fully suppresses SwiftTerm's own mouseDown
        // (no text selection / caret placement happens for a click that
        // opened a file). Returning the event unchanged when nothing
        // resolved lets normal Cmd+click-through-to-selection behavior
        // proceed exactly as before this feature existed.
        commandClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] ev in
            guard let self, ev.window === self.window, ev.modifierFlags.contains(.command) else { return ev }
            return self.handleCommandClick(at: ev.locationInWindow) ? nil : ev
        }
        if useSharedTab0 {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sharedBackendDidTerminate(_:)),
                name: .claudeBackendDidTerminate, object: nil
            )
            installShieldButton()
            NotificationCenter.default.addObserver(
                self, selector: #selector(skipPermissionsStateChanged),
                name: .opusSkipPermissionsChanged, object: nil
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(sharedBackendDidSpawn(_:)),
                name: .claudeBackendDidSpawn, object: nil
            )
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Layout (new — container-specific)

    private func buildSubviews() {
        let area = NSView()
        area.translatesAutoresizingMaskIntoConstraints = false
        addSubview(area)
        // Fix round 2 (v1.4.1): initial constant matches updateTabIndicator's
        // "hidden" branch (-(14 + 4)) instead of 0 — see the doc comment on
        // meterBottom below for why the default (single-tab) state has to be
        // right from construction, not just after the first tab change.
        let bottom = area.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(14 + 4))
        // v1.6 backlog Task 3: trailing constraint is now a variable, not a
        // fixed pin — `0` (closed) by default, `-TodoDrawerView.width` while
        // the todo drawer is open (toggleTodoDrawer), so the terminal area
        // shrinks to make room instead of drawing underneath the drawer.
        let trailing = area.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            area.topAnchor.constraint(equalTo: topAnchor),
            area.leadingAnchor.constraint(equalTo: leadingAnchor),
            trailing,
            bottom
        ])
        terminalArea = area
        terminalAreaBottomConstraint = bottom
        terminalAreaTrailingConstraint = trailing

        let bar = OpusTabBar(frame: .zero)
        bar.isHidden = true
        bar.alphaValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.onSwitch = { [weak self] idx in self?.switchTab(to: idx) }
        addSubview(bar)
        let heightC = bar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -4),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 8),
            heightC
        ])
        tabBar = bar
        tabBarHeightConstraint = heightC

        // Status rail (visual-harmonization spec, section 1 "Rail de statut")
        // — bottom-of-panel strip that now carries BOTH the context-usage
        // fill+readout (formerly ContextMeterBar + the top-right "ctx NN%"
        // label) AND the activity dot (formerly the top-right PaneActivityDot),
        // per the spec's "le statut passif descend, l'action reste en haut."
        // OWN bottom constraint to the container's bottomAnchor, switched in
        // updateTabIndicator alongside tabBarHeightConstraint/
        // terminalAreaBottomConstraint — same mechanism the old
        // contextMeterBottomConstraint used, and for the same reason
        // (`rail.bottomAnchor == bar.topAnchor` would track the bar's own
        // bottomAnchor, which sits at container-bottom+8 regardless of its
        // height, not the bar's actual visible top edge).
        //
        // No explicit height constraint — StatusRailView's intrinsicContentSize
        // (the readout label's own height, measured 13pt for the 10pt
        // monospaced-digit font) drives it, per StatusRailView's own doc
        // comment and task-2-report.md's layout arithmetic. Leading/trailing
        // pinned with zero inset, same as the old meter — the container's
        // own leading/trailing edges already carry the panel's 14pt inset
        // from the blur, so no additional constant belongs here.
        //
        // Initial bottom constant already matches updateTabIndicator's
        // "hidden" branch (-4) rather than deferring to updateTabIndicator(),
        // for the same reason the old meter did: that function only ever
        // runs from switchTab(to:), so a session that starts and stays on
        // tab 0 would otherwise never correct it (see init's own
        // updateTabIndicator() call). Always present in the view hierarchy
        // (never isHidden) — visibility is alpha-only (fraction == nil), so
        // a fade-in/out never needs a relayout pass. Added AFTER
        // terminalArea above (z-above it already — no reorder needed).
        let rail = StatusRailView(frame: .zero)
        rail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rail)
        let railBottom = rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.trailingAnchor.constraint(equalTo: trailingAnchor),
            railBottom
        ])
        statusRail = rail
        railBottomConstraint = railBottom

        // Todo drawer (v1.6 backlog Task 3) — right-side, fixed 260pt width,
        // hidden by default. Top pinned flush to the container's own top
        // (same as terminalArea); trailing flush to the container's own
        // trailing (the drawer IS the container's rightmost edge while
        // open — there's nothing further right for it to leave room for).
        // Bottom is the one non-obvious anchor: it does NOT go all the way
        // to the container's bottomAnchor (that would draw OVER the status
        // rail and, when 2+ tabs exist, the tab bar too — fix round finding
        // F6: this drawer is added LAST, below, i.e. it sits ABOVE both of
        // them in z-order, not the other way around, so an overlapping
        // drawer would visually hide them rather than being clipped by
        // them). Instead its own bottom constraint is switched in lockstep
        // with terminalAreaBottomConstraint inside updateTabIndicator, using the
        // literal SAME constants (terminalAreaBottomShown/Hidden) — so the
        // drawer's bottom edge always sits at EXACTLY the same y-position
        // as terminalArea's own bottom edge, which is already guaranteed
        // (by that existing arithmetic) to clear both the rail and the tab
        // bar in either tab-count state. See task-3-report.md for the
        // worked-out numbers.
        let drawer = TodoDrawerView(frame: .zero)
        drawer.translatesAutoresizingMaskIntoConstraints = false
        drawer.isHidden = true
        addSubview(drawer)
        let drawerBottom = drawer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(14 + 4))
        NSLayoutConstraint.activate([
            drawer.topAnchor.constraint(equalTo: topAnchor),
            drawer.trailingAnchor.constraint(equalTo: trailingAnchor),
            drawer.widthAnchor.constraint(
                equalToConstant: RightDockGeometry.width(for: .tasks)),
            drawerBottom
        ])
        todoDrawer = drawer
        todoDrawerBottomConstraint = drawerBottom

        // Artifacts drawer (Task 8) — second occupant of the right dock,
        // built the same way as the Tasks drawer directly above. Built and
        // registered BEFORE `RightDock` is constructed: `RightDock.show`
        // sets the terminal's trailing constant from the requested
        // occupant's width whether or not it has a view for that occupant,
        // so a dock built without this view would still shrink the
        // terminal by RightDockGeometry.width(for: .artifacts) and show
        // nothing in the gap.
        let artifactsDrawerView = ArtifactsDrawerView(frame: .zero)
        artifactsDrawerView.translatesAutoresizingMaskIntoConstraints = false
        artifactsDrawerView.isHidden = true
        addSubview(artifactsDrawerView)
        // Bottom edge tracks terminalAreaBottomConstraint's own constant,
        // never the container's raw bottomAnchor: the status rail plus tab
        // bar band at the true bottom grows and shrinks with the tab count,
        // and the drawer must clear both in every state, not only the one
        // on screen when it was built. Same reasoning as TodoDrawerView.
        let artifactsBottom = artifactsDrawerView.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -(14 + 4))
        NSLayoutConstraint.activate([
            artifactsDrawerView.topAnchor.constraint(equalTo: topAnchor),
            artifactsDrawerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            artifactsDrawerView.widthAnchor.constraint(
                equalToConstant: RightDockGeometry.width(for: .artifacts)),
            artifactsBottom
        ])
        artifactsDrawer = artifactsDrawerView
        artifactsDrawerBottomConstraint = artifactsBottom

        rightDock = RightDock(
            views: [.tasks: drawer, .artifacts: artifactsDrawerView],
            terminalTrailing: terminalAreaTrailingConstraint,
            onChange: { [weak self] occupant in
                guard let self else { return }
                self.updateTopRightRow(drawerOpen: RightDockGeometry.isOpen(occupant))
                self.layoutSubtreeIfNeeded()
                if occupant == .tasks {
                    self.refreshTodoDrawer()
                    self.startTodoDrawerTimer()
                } else {
                    self.stopTodoDrawerTimer()
                }

                if occupant == .artifacts {
                    self.refreshArtifacts()
                    self.startArtifactsTimer()
                } else {
                    self.stopArtifactsTimer()
                }
            })

        layoutSubtreeIfNeeded()
    }

    // MARK: Cockpit — context-window burn meter (Lot 3, Task 4)
    //
    // A 10s Timer, started once this container's view first enters a window
    // (viewDidMoveToWindow — see below) and reads the ACTIVE tab's transcript
    // tail on every fire to update `statusRail`. In practice it then
    // runs for the app's lifetime: both hosts hide via orderOut/alpha
    // (QuickTerminalPanel's slide-out, MainTerminalWindow's orderOut), never
    // by detaching the view from its window, so `window != nil` stays true
    // and the timer is never stopped again after that first start. Accepted
    // cost — a 10s no-op timer tick isn't worth tracking visibility for. The
    // read + JSON scan happens on a background queue; only the final NSView
    // property writes happen on main.
    //
    // Both TerminalContainerView instances (QuickTerminalPanel's and
    // MainTerminalWindow's) run this independently when both are visible —
    // see the class-level doc comment on `useSharedTab0` for why there are
    // two containers at all. That means up to two independent 32KB tail
    // reads of the SAME transcript file every 10s when both surfaces are on
    // screen simultaneously. Accepted: 32KB every 10s is noise-level disk
    // I/O, each container's bar only ever needs to reflect ITS OWN active
    // tab (which can legitimately differ between the panel and the main
    // window — e.g. panel on tab 0, main window's user-clicked to tab 2),
    // and de-duplicating would mean threading cross-container coordination
    // through for a cost that was never real to begin with.

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startContextMeterTimer()
        } else {
            stopContextMeterTimer()
        }
    }

    private func startContextMeterTimer() {
        guard contextMeterTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshContextMeter()
        }
        timer.tolerance = 2
        contextMeterTimer = timer
        // Fire once immediately rather than leaving the bar blank (alpha 0,
        // its initial state) for up to 10s after the window appears.
        refreshContextMeter()
    }

    private func stopContextMeterTimer() {
        contextMeterTimer?.invalidate()
        contextMeterTimer = nil
    }

    /// The session id bound to the CURRENTLY ACTIVE tab's active pane: only
    /// the spawn-order-bound id (`sessionId(for:)`) once that pane's
    /// `SessionStart` hook has actually matched it. `nil` otherwise —
    /// including for a not-yet-bound SHARED pane.
    ///
    /// Two consumers as of v1.6 backlog Task 3: the context meter
    /// (`refreshContextMeter`, reading the session's transcript) and the
    /// todo drawer (`refreshTodoDrawer`, reading the session's task list) —
    /// both need exactly the same "which session is the user looking at
    /// right now" answer, so this is the one place that answers it rather
    /// than two independent copies of the tab/pane-index bookkeeping below.
    ///
    /// Fix round 1: this used to fall back to
    /// `ClaudeSessionLocator.mostRecentSessionId(for:)` for an unbound
    /// shared pane. Removed — that locator answers "what's the newest
    /// transcript in this cwd's project dir," which is NOT the same
    /// question as "what's THIS pane's session." The owner's real working
    /// directory routinely has a dozen-plus concurrently live transcripts
    /// (subagents, other Opus surfaces, sessions resumed elsewhere) all
    /// writing into the same project dir, so at cold start (the exact
    /// moment this fallback fired — before the first `SessionStart` hook
    /// lands) "most recently modified" can easily be someone else's
    /// unrelated, still-running session. Showing that session's usage next
    /// to a completely different pane is actively misleading — worse than
    /// showing nothing. No fallback: the bar (and, since Task 3, the
    /// drawer) just stays blank/empty for the few seconds until
    /// `ClaudeStateStore` binds the real id. The todo drawer's empty state
    /// ("No tasks in this session") is this exact same rule applied to a
    /// second surface — see `refreshTodoDrawer`'s doc comment.
    private func activeSessionId() -> String? {
        guard tabPanes.indices.contains(activeTabIndex) else { return nil }
        let idx = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
        let panes = tabPanes[activeTabIndex]
        guard panes.indices.contains(idx) else { return nil }
        return sessionId(for: panes[idx])
    }

    /// Locate `<sessionId>.jsonl` under `~/.claude/projects/<encoded cwd>/`,
    /// trying both of `ClaudeSessionLocator`'s known cwd-encoding schemes
    /// (see its doc comment) rather than duplicating that encoding logic
    /// here.
    private static func transcriptURL(sessionId: String, cwd: String) -> URL? {
        let fm = FileManager.default
        let projectsRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        for name in ClaudeSessionLocator.projectDirNameCandidates(for: cwd) {
            let url = projectsRoot.appendingPathComponent(name).appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Tail-read (see `ContextMeter.tailBudgetBytes`) the transcript for
    /// `sessionId`/`cwd` via `FileHandle` seek — never a whole-file read, a
    /// live transcript can run to tens of megabytes. `nil` when the file
    /// doesn't exist (session id not yet flushed to disk, wrong cwd, or a
    /// stale id from a closed/replaced session) or can't be opened.
    private static func readTranscriptTail(sessionId: String, cwd: String) -> Data? {
        guard let url = transcriptURL(sessionId: sessionId, cwd: cwd),
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tailStart = size > UInt64(ContextMeter.tailBudgetBytes) ? size - UInt64(ContextMeter.tailBudgetBytes) : 0
        guard (try? handle.seek(toOffset: tailStart)) != nil else { return nil }
        return try? handle.readToEnd()
    }

    /// Timer tick (and the one immediate call from `startContextMeterTimer`)
    /// — resolves the active session, reads+parses off the main queue, then
    /// hops back to apply the result to the bar.
    ///
    /// Fix round 1: bumps `contextMeterGeneration` and captures it BEFORE
    /// dispatching, so a result that comes back after a NEWER refresh has
    /// already started gets dropped instead of clobbering fresher (or
    /// intentionally-blanked) state — a fast tab switch can otherwise have
    /// two background reads in flight at once, and GCD gives no ordering
    /// guarantee between them. Same generation-token pattern as
    /// `SessionSwitcherPanel.scanGeneration` (see its doc comment).
    private func refreshContextMeter() {
        contextMeterGeneration += 1
        let generation = contextMeterGeneration

        guard let sessionId = activeSessionId() else {
            statusRail.fraction = nil
            statusRail.readout = nil
            contextTooltipSentence = nil
            updateStatusRailTooltip()
            return
        }
        let cwd = OpusPreferences.shared.workingDirectory
        let configuredLimit = OpusPreferences.shared.contextLimitTokens
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let usage = Self.readTranscriptTail(sessionId: sessionId, cwd: cwd)
                .flatMap { ContextMeter.usage(fromTranscriptTail: $0) }
            let result = usage.map { u in
                (tokens: u.tokens, limit: ContextMeter.resolveLimit(
                    modelId: u.modelId,
                    observedTokens: u.tokens,
                    configuredLimit: configuredLimit
                ))
            }
            DispatchQueue.main.async {
                guard let self, self.contextMeterGeneration == generation else { return }
                self.applyContextMeterResult(result)
            }
        }
    }

    /// Main-thread-only: paint the rail (or hide it) from a background
    /// scan's result. `nil` (no transcript, no usage-bearing record yet, or
    /// the session is otherwise unreadable) hides the rail's bar+label
    /// entirely (`statusRail.fraction = nil`) rather than drawing a
    /// misleading 0%. The rail's FILL color (cyan at/under 70%, amber to
    /// 85%, red beyond — `OpusTheme.contextColor`) is StatusRailView's job,
    /// not this container's; this function only feeds it fraction/readout/
    /// tooltip. (The label's own color is a separate rule inside
    /// StatusRailView.updateLabelColor: cream at/under 70%, matching
    /// contextColor above that — cream is the resting text color, not part
    /// of the cyan/amber/red fill scale.)
    private func applyContextMeterResult(_ result: (tokens: Int, limit: Int)?) {
        guard let result, result.limit > 0 else {
            statusRail.fraction = nil
            statusRail.readout = nil
            contextTooltipSentence = nil
            updateStatusRailTooltip()
            return
        }
        let rawFraction = Double(result.tokens) / Double(result.limit)
        let clampedFraction = CGFloat(min(max(rawFraction, 0), 1))
        statusRail.fraction = clampedFraction
        statusRail.readout = StatusRailView.readoutText(tokens: result.tokens, limit: result.limit)
        let kTokens = Int((Double(result.tokens) / 1000).rounded())
        let kLimit = Int((Double(result.limit) / 1000).rounded())
        // Deliberately computed from the UNCLAMPED rawFraction, unlike the
        // rail's own `.fraction` above — a session that's blown past its
        // limit should say so ("173%"), even though the rail's fill visually
        // caps at a full-width fill.
        let percent = Int((rawFraction * 100).rounded())
        contextTooltipSentence = "\(kTokens)k / \(kLimit)k tokens (\(percent)%)"
        updateStatusRailTooltip()
    }

    /// Word describing `activity` for the tooltip's second line — mirrors
    /// the per-state tooltips the deleted `PaneActivityDot` used to show
    /// (Task 6 follow-up: `StatusRailView`'s single `tooltipText` otherwise
    /// only ever carries the context sentence, so hovering the dot stopped
    /// explaining what it means). `nil` for `.idle`, matching
    /// `OpusTheme.activityColor` — no dot, no line.
    private func activityTooltipLine(_ activity: PaneActivity) -> String? {
        switch activity {
        case .idle: return nil
        case .working: return "Claude is working"
        case .needsInput: return "Claude needs input"
        case .done: return "Claude finished"
        }
    }

    /// Recomposes `statusRail.tooltipText` from the two independent signals
    /// that feed it: `contextTooltipSentence` (the context-meter sentence,
    /// `nil` when there's no data — rail fill invisible) and
    /// `statusRail.activity`'s state word (`nil` when `.idle` — no dot
    /// either). Called from BOTH refresh paths that can change either half —
    /// `applyContextMeterResult`/`refreshContextMeter` when the context part
    /// changes, and `refreshTabBarStates` when ONLY the activity part
    /// changes — so hovering the rail always reflects the latest of both,
    /// not just whichever path happened to run most recently.
    ///
    /// The activity line is kept even when there's no context sentence
    /// (rail fill invisible): the dot has its own independent lifecycle
    /// (StatusRailView.fraction's doc comment — Claude can be `.working`
    /// before the first transcript read produces a usage fraction), so it
    /// can be the only thing visible on the strip and still deserves an
    /// explanation on hover.
    private func updateStatusRailTooltip() {
        let activityLine = activityTooltipLine(statusRail.activity)
        switch (contextTooltipSentence, activityLine) {
        case let (.some(context), .some(activity)):
            statusRail.tooltipText = "\(context)\n\(activity)"
        case let (.some(context), nil):
            statusRail.tooltipText = context
        case let (nil, .some(activity)):
            statusRail.tooltipText = activity
        case (nil, nil):
            statusRail.tooltipText = nil
        }
    }

    // MARK: Cockpit — todo drawer (v1.6 backlog Task 3, Cmd+Shift+T)
    //
    // Same shape as the context meter block above: a Timer that only runs
    // while the drawer is actually visible (unlike the context meter's,
    // which — per that block's own doc comment — runs for the app's
    // lifetime once started; the drawer's is explicitly narrower per the
    // brief: "timer 5s uniquement quand le tiroir est visible"), a
    // generation counter guarding the background→main handoff exactly like
    // `contextMeterGeneration`, and a background read (TaskListReader.load,
    // disk I/O + JSON parse) that only ever touches the drawer's `tasks`
    // property back on main.

    /// Pin `button`'s trailing edge into the top-right row (see
    /// `TopRightButtonRow`) at `base` points from the terminal area's
    /// trailing edge, and keep it in step with the row across drawer
    /// toggles. `button` does NOT have to be a subview of this container —
    /// the Quick Terminal panel's pin/↗ buttons live in the panel's blur
    /// view, one level above it — it only has to already share an ancestor
    /// with the container, which is all Auto Layout needs to resolve the
    /// constraint at their nearest common ancestor.
    func pinToTopRightRow(_ button: NSView, base: CGFloat) {
        let constraint = button.trailingAnchor.constraint(
            equalTo: terminalArea.trailingAnchor,
            constant: TopRightButtonRow.trailingConstant(
                base: base, drawerOpen: RightDockGeometry.isOpen(rightDock?.occupant ?? .none)))
        topRightRowConstraints.append((constraint, base))
        constraint.isActive = true
    }

    private func updateTopRightRow(drawerOpen: Bool) {
        for entry in topRightRowConstraints {
            entry.constraint.constant = TopRightButtonRow.trailingConstant(
                base: entry.base, drawerOpen: drawerOpen)
        }
    }

    // The dangerous-mode shield button (installShieldButton, above)
    // used to float at a FIXED offset from the container's own
    // trailing edge, which sat inside the drawer's top-right corner
    // whenever the drawer was open. Fix round finding F2: rather
    // than hiding the shield for the drawer's duration (which kills
    // the only at-a-glance "claude is running
    // --dangerously-skip-permissions" signal), the button's trailing
    // anchor is now pinned to `terminalArea.trailingAnchor` instead
    // of the container's — so flipping this same
    // `terminalAreaTrailingConstraint` that shrinks the terminal
    // area also slides the shield left with it, landing inside the
    // now-narrower terminal area instead of under the drawer. No
    // shield-specific bookkeeping needed here anymore;
    // `refreshShieldButton()` still governs the button's visibility
    // on its own, unrelated axis (skip-permissions state, not drawer
    // state).
    //
    // Palette fix round: the shield was the ONLY button that moved.
    // Its row siblings (the panel's pin and ↗ buttons) were still
    // pinned to the panel's own trailing edge and stayed put, ending
    // up inside the drawer's top-right corner — see
    // `TopRightButtonRow`. They are now pinned to the same moving
    // anchor via `pinToTopRightRow`, and `updateTopRightRow` applies
    // the row-wide shift that keeps the rightmost one clear of the
    // drawer's leading edge.
    func toggleTodoDrawer() {
        rightDock?.toggle(.tasks)
    }

    private func startTodoDrawerTimer() {
        guard todoDrawerTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTodoDrawer()
        }
        timer.tolerance = 1
        todoDrawerTimer = timer
    }

    /// Called from `toggleTodoDrawer()`'s close branch. Also the reason a
    /// closed drawer's timer really does stop rather than silently leaking:
    /// `Timer.invalidate()` removes it from the run loop immediately (no
    /// further fires can land, in-flight or otherwise — a fire already
    /// dispatched to the background queue before invalidate() still lands,
    /// but its result is dropped by `refreshTodoDrawer`'s own generation
    /// guard below once it hops back to main, same as any other stale
    /// background read in this file), and `todoDrawerTimer = nil` lets the
    /// next `startTodoDrawerTimer()` call (the drawer's next open) pass its
    /// own `guard todoDrawerTimer == nil` and actually schedule a fresh one
    /// instead of no-op'ing forever.
    private func stopTodoDrawerTimer() {
        todoDrawerTimer?.invalidate()
        todoDrawerTimer = nil
    }

    /// Timer tick (and the immediate call from `toggleTodoDrawer`'s open
    /// branch, plus `paneActivityChanged`/`switchTab`'s immediate
    /// refreshes) — resolves the active session, reads+parses off a
    /// background queue, then hops back to apply the result to the drawer.
    /// Bumps `todoDrawerGeneration` and captures it BEFORE dispatching, so
    /// a result that comes back after a NEWER refresh has already started
    /// (e.g. two tab switches in quick succession while the drawer is open)
    /// gets dropped instead of clobbering fresher state — identical
    /// staleness guard to `refreshContextMeter`'s `contextMeterGeneration`,
    /// see that function's own doc comment for the full rationale.
    ///
    /// No bound session for the active pane (a brand-new pane whose
    /// SessionStart hook hasn't landed yet, or a shared pane still waiting
    /// on `sharedBackendDidSpawn`) → empty tasks, i.e. the drawer's own
    /// "No tasks in this session" empty state. This is the SAME "no data
    /// beats wrong data" rule `activeSessionId()`'s doc comment describes
    /// for the context meter: showing some OTHER session's task list next
    /// to a pane that isn't actually that session would be actively
    /// misleading, not just incomplete, so this deliberately does not fall
    /// back to "most recent session" or any other guess.
    private func refreshTodoDrawer() {
        // Guards every caller at once (the timer already only runs while
        // visible — see startTodoDrawerTimer/stopTodoDrawerTimer — but
        // paneActivityChanged and switchTab below call this unconditionally
        // on every activity change / tab switch, which fire far more often
        // than the drawer is actually open; a hidden drawer has nothing on
        // screen worth a disk read+parse for).
        guard rightDock?.occupant == .tasks else { return }
        // Fix round finding F3: a refresh already in flight covers whatever
        // this call would have asked for too (it started more recently than
        // this event), so drop this trigger rather than paying for a second
        // overlapping disk read — the timer (while open) and every other
        // activity/tab-switch event during the burst will still land a
        // fresh read the moment the in-flight one clears the flag below.
        guard !todoDrawerRefreshInFlight else { return }
        todoDrawerGeneration += 1
        let generation = todoDrawerGeneration

        guard let sessionId = activeSessionId() else {
            todoDrawer.tasks = []
            return
        }
        todoDrawerRefreshInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tasks = TaskListReader.load(sessionId: sessionId, tasksDir: Self.tasksDir)
            DispatchQueue.main.async {
                guard let self else { return }
                self.todoDrawerRefreshInFlight = false
                guard self.todoDrawerGeneration == generation else { return }
                self.todoDrawer.tasks = tasks
            }
        }
    }

    // MARK: Artifacts drawer (Lot artifacts-drawer, Task 9, Cmd+Shift+A)

    /// Same shape as the todo drawer's pipeline: a Timer that only runs
    /// while the drawer is the dock's occupant, a generation counter
    /// guarding the background to main handoff, and an in-flight flag so a
    /// burst of triggers does not stack overlapping disk reads.
    ///
    /// The interval is 1.5s rather than the todo drawer's 5s because an
    /// incremental read of the bytes appended since the last tick is far
    /// cheaper than the todo drawer's full directory scan, and because a
    /// file Claude just wrote should show up while the user is still
    /// looking for it.
    private func startArtifactsTimer() {
        guard artifactsTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshArtifacts()
        }
        timer.tolerance = 0.3
        artifactsTimer = timer
    }

    private func stopArtifactsTimer() {
        artifactsTimer?.invalidate()
        artifactsTimer = nil
    }

    private func refreshArtifacts() {
        guard rightDock?.occupant == .artifacts else { return }
        guard !artifactsRefreshInFlight else { return }

        guard let sessionId = activeSessionId() else {
            artifactsDrawer.artifacts = []
            return
        }
        let cwd = OpusPreferences.shared.workingDirectory
        // A different session means a different file. Resuming the new file
        // from the old file's offset would skip most of it, silently.
        if sessionId != artifactsSessionId {
            artifactsSessionId = sessionId
            artifactsOffset = 0
            artifactsDrawer.artifacts = []
        }
        guard let url = Self.transcriptURL(sessionId: sessionId, cwd: cwd) else {
            artifactsDrawer.artifacts = []
            return
        }

        artifactsGeneration += 1
        let generation = artifactsGeneration
        let offset = artifactsOffset
        let existing = artifactsDrawer.artifacts
        artifactsRefreshInFlight = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = TranscriptArtifactReader.read(
                url: url, from: offset, existing: existing)
            DispatchQueue.main.async {
                guard let self else { return }
                self.artifactsRefreshInFlight = false
                guard self.artifactsGeneration == generation else { return }
                self.artifactsOffset = result.offset
                self.artifactsDrawer.artifacts = result.artifacts
            }
        }
    }

    func toggleArtifactsDrawer() {
        rightDock?.toggle(.artifacts)
    }

    // MARK: Artifacts drawer key routing (Task 10)

    /// Whether the artifacts drawer is the dock's current occupant. Gates
    /// every one of the three forwarding methods below so their key
    /// monitors only fire while the drawer is actually open.
    var artifactsDrawerIsOpen: Bool { rightDock?.occupant == .artifacts }
    func focusArtifactsFilter() { artifactsDrawer.focusFilter() }
    func handleArtifactsEscape() -> Bool { artifactsDrawer.handleEscape() }
    func handleArtifactsSpace() -> Bool { artifactsDrawer.handleSpace() }

    // MARK: Dangerous-mode shield button

    /// Floating toggle at the container's top-right (the tab bar is hidden
    /// with a single tab, so it can't host this). Orange = claude is running
    /// with --dangerously-skip-permissions; click restarts the shared session
    /// back into the same conversation with the flag flipped.
    private func installShieldButton() {
        let btn = NSButton(title: "", target: self, action: #selector(shieldTapped))
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.setAccessibilityLabel("Skip permissions toggle")
        btn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(btn)
        // Fix round finding F2: pinned to `terminalArea.trailingAnchor`, NOT
        // the container's own `trailingAnchor` — `terminalArea`'s trailing
        // edge is the one that moves (`terminalAreaTrailingConstraint`, see
        // `toggleTodoDrawer()`) when the todo drawer opens, so the shield
        // slides left in lockstep with the terminal area instead of sitting
        // fixed under the drawer's top-right corner. Offset preserved
        // (-28) relative to that anchor, same as it was relative to the
        // container's when the drawer never moved anything.
        //
        // Palette fix round: that pin now goes through `pinToTopRightRow`,
        // the same call the panel's pin/↗ buttons use, so all three move as
        // one row instead of the shield alone (see `TopRightButtonRow`).
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            btn.widthAnchor.constraint(equalToConstant: 24),
            btn.heightAnchor.constraint(equalToConstant: 22)
        ])
        pinToTopRightRow(btn, base: TopRightButtonRow.shieldBase)
        shieldButton = btn

        // Right-click / ctrl-click: choose a --permission-mode preset. Skip
        // Permissions (left-click) always wins over these when active — see
        // composeSpawnCommand.
        let menu = NSMenu()
        for mode in OpusPermissionMode.allCases {
            let item = NSMenuItem(title: mode.displayName,
                                  action: #selector(permissionModePicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }
        btn.menu = menu   // right-click opens it

        refreshShieldButton()
    }

    private func refreshShieldButton() {
        guard let btn = shieldButton else { return }
        let active = ClaudeBackend.shared.skipPermissionsActive
        btn.image = NSImage(
            systemSymbolName: active ? "shield.slash.fill" : "shield.fill",
            accessibilityDescription: "Skip permissions"
        )
        btn.contentTintColor = active
            ? OpusTheme.amber
            : OpusTheme.cream(0.45)
        btn.toolTip = active
            ? "Skip permissions: ON. Claude runs tools without asking. Click to restore prompts (restarts into the same conversation)."
            : "Skip permissions: OFF. Click to relaunch with --dangerously-skip-permissions (restarts into the same conversation)."

        // Re-state the permission-mode menu's checkmark to match the current
        // pref — this runs on every skipPermissions flip too, since the
        // shield's own toggle changes what "active" flag combo is in effect.
        let current = OpusPreferences.shared.permissionMode
        for item in btn.menu?.items ?? [] {
            item.state = (item.representedObject as? String == current.rawValue) ? .on : .off
        }
    }

    @objc private func shieldTapped() {
        ClaudeBackend.shared.toggleSkipPermissions()
    }

    @objc private func skipPermissionsStateChanged() {
        refreshShieldButton()
    }

    @objc private func permissionModePicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = OpusPermissionMode(rawValue: raw),
              mode != OpusPreferences.shared.permissionMode else { return }   // re-picking the checked mode must not kill a running turn
        OpusPreferences.shared.permissionMode = mode
        refreshShieldButton()
        ClaudeBackend.shared.restart(resume: true)   // same conversation, new flags
    }

    // MARK: Cockpit — Cmd+click file[:line] → editor (Lot 3, Task 5)

    /// Hit-test every visible pane in the ACTIVE tab (splits put more than
    /// one on screen at once; other tabs are hidden and out of scope) for
    /// the one containing `windowPoint`, read the terminal line under the
    /// click, try to resolve a file reference, and open it if the file
    /// actually exists. Returns `true` only when something was opened —
    /// that's what tells the installing monitor whether to swallow the
    /// click (suppress selection) or let it fall through to SwiftTerm.
    private func handleCommandClick(at windowPoint: NSPoint) -> Bool {
        guard tabPanes.indices.contains(activeTabIndex) else { return false }
        for pane in tabPanes[activeTabIndex] {
            let terminal = pane.terminal
            guard !terminal.isHidden else { continue }
            let local = terminal.convert(windowPoint, from: nil)
            guard terminal.bounds.contains(local) else { continue }

            guard let hit = resolvePathClick(in: terminal, at: local) else { return false }
            let cwd = OpusPreferences.shared.workingDirectory
            guard let candidate = PathDetector.extract(line: hit.text, clickColumn: hit.col, cwd: cwd)
            else { return false }

            // A bare file mention ending a sentence ("...in src/Foo.swift.
            // Please check.") swallows the sentence-ending period into the
            // token — '.' is a legitimate path character (dotfiles,
            // extensions), so the scan can't tell it apart from one that
            // isn't. If the primary candidate doesn't exist, retry once
            // with trailing dots stripped before giving up. Line-number
            // handling is untouched: a real `:line` citation never has a
            // trailing dot in the first place (the suffix parse stops at
            // the first non-digit), so this retry only ever fires for the
            // no-line-number shape.
            let fm = FileManager.default
            if fm.fileExists(atPath: candidate.path) {
                openInEditor(path: candidate.path, line: candidate.line)
                return true
            }
            if let stripped = PathDetector.trailingDotStripped(candidate.path), fm.fileExists(atPath: stripped) {
                openInEditor(path: stripped, line: candidate.line)
                return true
            }
            return false
        }
        return false
    }

    /// Maps a click already known to be inside `terminal`'s bounds to
    /// (line text, column). Returns `nil` on any out-of-range math rather
    /// than clamping here — PathDetector.extract does its own column
    /// clamping against the LINE text it's given, but a column outside the
    /// terminal's actual `cols`/`rows` grid means the click missed the
    /// glyph area entirely (e.g. landed on the scroller strip) and there's
    /// no line to read at all.
    private func resolvePathClick(in terminal: TerminalView, at local: NSPoint) -> (text: String, col: Int)? {
        let term = terminal.getTerminal()
        let cols = term.cols
        let rows = term.rows
        guard cols > 0, rows > 0 else { return nil }

        // MacTerminalView always reserves a fixed-width vertical scroller
        // strip on the trailing edge — `cols` itself is computed elsewhere
        // (Mac/MacTerminalView.swift's `getEffectiveWidth`) from
        // `(frame.width - scrollerWidth) / cellWidth`, NOT `frame.width /
        // cellWidth`. Replicating `frame.width / cols` here (the brief's
        // literal suggestion) would understate the true cell width and
        // drift every hit column left of the actual click as x grows —
        // small in a narrow pane, several columns off near the right edge
        // of a wide one. `scrollerWidth` itself isn't exposed by SwiftTerm,
        // but it's just `NSScroller.scrollerWidth(for:scrollerStyle:)` (a
        // plain AppKit API) with the same `.regular`/`.legacy` arguments
        // MacTerminalView hardcodes, so it's reproducible from outside.
        let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        let textWidth = max(terminal.bounds.width - scrollerWidth, 1)
        let cellWidth = textWidth / CGFloat(cols)
        let cellHeight = terminal.bounds.height / CGFloat(rows)
        guard cellWidth > 0, cellHeight > 0 else { return nil }

        let col = Int(floor(local.x / cellWidth))
        // TerminalView is never flipped (no `isFlipped` override anywhere
        // in SwiftTerm's Apple/Mac backend — confirmed by reading
        // Apple/AppleTerminalView.swift and Mac/MacTerminalView.swift), so
        // it uses AppKit's default: bounds.y = 0 is the BOTTOM of the view,
        // y grows upward. Row 0 on screen is the TOP, so distance from the
        // top — what row math wants — is `bounds.height - local.y`.
        let rowOnScreen = Int(floor((terminal.bounds.height - local.y) / cellHeight))
        guard col >= 0, col < cols, rowOnScreen >= 0, rowOnScreen < rows else { return nil }

        // `Terminal.getLine(row:)` takes a VIEWPORT-relative row, not an
        // absolute scrollback index, despite its doc comment's misleading
        // "relative to the scroll buffer" wording: the implementation is
        // `buffer.lines[row + buffer.yDisp]` guarded by `row >= rows` (the
        // small on-screen row count, ~25-50, not the scrollback depth) —
        // confirmed against SwiftTerm's own HeadlessUsage.md example,
        // which loops `for row in 0..<terminal.rows { terminal.getLine(row:
        // row) }`. So `rowOnScreen` (0 = top visible row, same convention
        // this function already computed) is exactly the right argument.
        // Adding `getTopVisibleRow()` first — what the brief suggested —
        // would double-count `yDisp` and blow that `row >= rows` guard for
        // any pane with scrollback beyond one screen, returning nil on
        // almost every real click. getTopVisibleRow() is therefore
        // deliberately NOT used here.
        guard let bufferLine = term.getLine(row: rowOnScreen) else { return nil }
        return (bufferLine.translateToString(trimRight: true), col)
    }

    /// Run `OpusPreferences.editorCommand` with `{target}` replaced by the
    /// shell-quoted `path` (or `path:line`), off the main queue since
    /// `Process.waitUntilExit()` blocks. Falls back to
    /// `NSWorkspace.shared.open` — which at least opens the file in
    /// whatever app is registered for it — on a non-zero exit or a launch
    /// failure (e.g. the configured command isn't installed).
    private func openInEditor(path: String, line: Int?) {
        let target = line.map { "\(path):\($0)" } ?? path
        let command = OpusPreferences.shared.editorCommand
            .replacingOccurrences(of: "{target}", with: Self.shellQuote(target))
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            let openFallback = { DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } }
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 { openFallback() }
            } catch {
                openFallback()
            }
        }
    }

    // MARK: Find bar (Cmd+F scrollback search over SwiftTerm's built-in engine)

    /// Fix 2 (v1.4.2) — which way a find navigation moves: `.up` = older/
    /// earlier lines (SwiftTerm's findPrevious), `.down` = newer/toward the
    /// bottom (findNext). Same up/down framing as onSearchUp/onSearchDown.
    /// Internal (not `private`), not `public` — v1.4.2 task-review Finding 2:
    /// `resolveMatchDisplay` below takes it as a parameter so tests can
    /// exercise the safety guard via `@testable import Opus`.
    enum FindDirection { case up, down }

    /// Fix 2 (v1.4.2) — our own 1-based "n / total" bookkeeping for the
    /// find-bar match counter. SwiftTerm's find cursor is entirely internal
    /// (SearchService/SearchEngine are not `public`), so there is no way to
    /// read "which match number is this" back out of SwiftTerm itself; this
    /// is purely our own approximation, advanced in lockstep with each
    /// successful navigation via `navigateFind`. It CAN drift from
    /// SwiftTerm's true cursor position if the buffer changes (new output
    /// streaming in) mid-search, since nothing re-validates it against
    /// SwiftTerm's live state — only a fresh navigation (or a term change,
    /// which resets it to 0) ever recomputes it.
    private var matchIndex = 0
    private var matchTotal = 0

    /// v1.4.2 task-review Finding 1 — bumped every time `navigateFind`
    /// kicks off a background harvest+count, and captured by that
    /// dispatch's completion closure. A completion whose captured
    /// generation no longer matches `matchCountGeneration` (a NEWER
    /// navigation started, or the term/bar was cleared in the meantime) is
    /// dropped instead of clobbering fresher state — same pattern as
    /// `contextMeterGeneration` (see `refreshContextMeter`'s doc comment
    /// above) and `SessionSwitcherPanel.scanGeneration`.
    private var matchCountGeneration = 0

    /// v1.4.2 task-review Finding 1 — short-lived cache of a harvest+count
    /// result, keyed by search term. Rapid arrow-key repeats (measured
    /// faster than the ~100ms+ a fresh scan can cost — see
    /// `harvestBufferLines`'s doc comment) hit this instead of
    /// re-harvesting/re-counting on every keystroke: the FIRST navigation
    /// for a term still pays the cost (harvest synchronously, count on a
    /// background queue — see `scheduleMatchCount`), but every repeat
    /// within `ttl` of the SAME term reuses the cached total synchronously,
    /// with no background hop at all.
    ///
    /// Invalidated by (a) a different search term, or (b) more than `ttl`
    /// elapsed — `isValid(for:terminalIdentity:)` checks both, plus a third
    /// structural guard this class needed regardless of the brief's (a)/(b)/
    /// (c) list: the harvested TERMINAL must also match. Without that, tab-
    /// switching (which leaves `lastSearchTerm` etc. alone — see
    /// `navigateFind`) and re-searching the SAME term in a DIFFERENT tab
    /// within `ttl` would apply the old tab's total to the new tab's
    /// buffer, since the jump itself always re-resolves `activeTerminal`
    /// fresh on every call regardless of caching. There is deliberately no
    /// (c) "buffer changed" invalidation: nothing PUBLIC on SwiftTerm's
    /// Terminal/Buffer offers a cheap dirty signal to hang that on.
    /// Checked (reading `.build/checkouts/SwiftTerm`): `BufferLine.isWrapped`
    /// and `Buffer.lines`/`linesTop` are all non-`public` (module-internal);
    /// the one PUBLIC candidate, `Terminal.getScrollInvariantUpdateRange()`,
    /// is continuously drained by `AppleTerminalView`'s own render pass via
    /// `terminal.clearUpdateRange()` (Apple/AppleTerminalView.swift:1572-1584)
    /// — by the time this cache would consult it, it no longer reflects
    /// "changed since I last looked," it reflects "changed since the view
    /// last redrew," which can be milliseconds ago regardless of whether
    /// OUR last harvest was 0.1s or 1.9s back. So this cache relies on
    /// (a)+(b) only, same as the brief authorized as a fallback.
    private struct HarvestCache {
        let term: String
        /// Which TerminalView was harvested — switching tabs (or splitting/
        /// closing panes) changes `activeTerminal` without necessarily
        /// closing the find bar's underlying state (`lastSearchTerm` etc.
        /// intentionally survive a tab switch, same as before this fix).
        /// Without pinning the cache to the terminal it came from, searching
        /// the SAME term again in a DIFFERENT tab within `ttl` would apply
        /// the old tab's total to the new tab's buffer — a real
        /// contradiction, not just staleness, since the jump itself always
        /// re-resolves `activeTerminal` fresh on every call.
        let terminalIdentity: ObjectIdentifier
        /// Stored alongside `total` per the brief, even though the current
        /// cache-hit path (`navigateFind`) only reads `total` back out —
        /// kept for any future feature that wants the actual harvested
        /// lines (e.g. a match-preview) without paying for a re-harvest.
        let lines: [String]
        let total: Int
        let timestamp: Date

        static let ttl: TimeInterval = 2.0

        func isValid(for term: String, terminalIdentity: ObjectIdentifier) -> Bool {
            self.term == term
                && self.terminalIdentity == terminalIdentity
                && Date().timeIntervalSince(timestamp) < Self.ttl
        }
    }
    private var harvestCache: HarvestCache?

    /// Single entry point for every find navigation: the bar's Enter/
    /// Shift+Enter/arrow keys (wired in toggleFindBar below) AND the
    /// Cmd+G/Cmd+Shift+G repeat hotkeys (searchUpInActivePane/
    /// searchDownInActivePane) all route through here, so the "n / total"
    /// counter stays correct no matter which path triggered the search.
    ///
    /// v1.4.2 task-review Finding 1 — the actual jump (`findPrevious`/
    /// `findNext`) is ALWAYS synchronous and immediate: it never waits on
    /// match counting, which is the part that was measured expensive (21ms
    /// harvest + 84ms count at the default 10k scrollback, 535ms at the
    /// old 50k cap — see `harvestBufferLines`'s doc comment). The counter
    /// text is then either updated immediately (cache hit —
    /// `HarvestCache.isValid(for:)`) or replaced with the "unknown position"
    /// placeholder right away, pending a background count landing
    /// (`scheduleMatchCount`) — never left showing a STALE label, and never
    /// shown for a stale term (a fresh term's real position is only shown
    /// once ITS count lands).
    ///
    /// v1.5 re-review of 43853ca (Finding: stale "no match" over a
    /// highlighted result) — the sequence this closes: search term A finds
    /// nothing (`applyMatchDisplay` writes "no match" synchronously, see the
    /// `guard found` branch below), then search term B's jump succeeds
    /// (`found == true`, and SwiftTerm has ALREADY highlighted it on screen)
    /// but is a cache miss, so its count goes async. Before this fix, the
    /// label sat at term A's stale "no match" for the ~84ms the background
    /// count took — directly contradicting the highlight the user could
    /// already see. Fixed in the cache-miss branch below: write the
    /// placeholder BEFORE dispatching, not after.
    private func navigateFind(term: String, direction: FindDirection) {
        guard !term.isEmpty else {
            // Fix 2 (v1.4.2): "empty when the search term is empty." This
            // deliberately does NOT touch `lastSearchTerm` — Cmd+G still
            // repeats whatever was last actually searched even if Enter
            // fires while the field is momentarily empty.
            matchIndex = 0
            matchTotal = 0
            matchCountGeneration += 1   // drop any in-flight count
            findBar?.updateMatchCounter("")
            return
        }
        if term != lastSearchTerm {
            matchIndex = 0   // fresh term — the old index no longer means anything
        }
        lastSearchTerm = term

        let found: Bool
        switch direction {
        case .up:   found = activeTerminal?.findPrevious(term) ?? false
        case .down: found = activeTerminal?.findNext(term) ?? false
        }

        // `terminal` (needed below to key the cache) is resolved fresh here
        // rather than reusing whatever `activeTerminal?.findPrevious`/
        // `findNext` above saw — `found == true` guarantees it was non-nil
        // at that call, and nothing else runs on this single thread in
        // between, so re-reading it is exactly the same value.
        guard found, let terminal = activeTerminal else {
            // SwiftTerm itself found nothing (or there's no active terminal
            // at all) — unambiguous, no need to harvest/count.
            matchCountGeneration += 1   // drop any in-flight count from a previous nav
            applyMatchDisplay(found: false, total: 0, direction: direction)
            return
        }
        let terminalIdentity = ObjectIdentifier(terminal)

        if let cache = harvestCache, cache.isValid(for: term, terminalIdentity: terminalIdentity) {
            applyMatchDisplay(found: true, total: cache.total, direction: direction)
            return
        }
        // v1.5 re-review of 43853ca — SwiftTerm already jumped to (and
        // highlighted) a match by this point, but the real "n / total"
        // count is about to go async below. Paint the placeholder onto the
        // bar RIGHT NOW rather than leaving whatever text was there before
        // this call — including a stale "no match" left over from a PRIOR
        // search term that failed (see this method's own doc comment above
        // for the exact repro) — sitting under a highlight it now
        // contradicts for the ~84ms the background count takes.
        //
        // Goes straight to `findBar?.updateMatchCounter`, NOT through
        // `applyMatchDisplay` — that would also overwrite `matchIndex`/
        // `matchTotal`, and `scheduleMatchCount`'s eventual completion still
        // needs THIS navigation's real `matchIndex` (captured below as
        // `previousIndex`) to compute the correct next position once the
        // count lands. Only the visible label changes here; the index
        // bookkeeping is untouched.
        let placeholder = Self.scheduledCountPlaceholder(previousIndex: matchIndex, direction: direction)
        findBar?.updateMatchCounter(placeholder)
        scheduleMatchCount(term: term, direction: direction, terminalIdentity: terminalIdentity)
    }

    /// v1.4.2 task-review Finding 1 — the actual side-effecting half of a
    /// match-count result: runs `Self.resolveMatchDisplay` (pure, unit-
    /// tested) and applies it to `matchIndex`/`matchTotal`/the bar. Called
    /// either synchronously from `navigateFind` (cache hit / not-found) or
    /// from `scheduleMatchCount`'s background-count completion.
    private func applyMatchDisplay(found: Bool, total: Int, direction: FindDirection) {
        let result = Self.resolveMatchDisplay(found: found, total: total, previousIndex: matchIndex, direction: direction)
        matchIndex = result.index
        matchTotal = result.total
        findBar?.updateMatchCounter(result.text)
    }

    /// v1.4.2 task-review Finding 2 — pure computation of the find-bar's
    /// next display text + matchIndex, given a jump's `found` result, the
    /// (possibly cached, possibly async-arrived) `total`, the PREVIOUS
    /// matchIndex, and which way the jump moved. Extracted as a pure static
    /// func so the SAFETY GUARD below is unit-testable without a live
    /// TerminalView/SwiftTerm buffer.
    ///
    /// v1.5.1 (owner smoke-test fix) — INDEX MEANING: `nextIndex` is the
    /// match's POSITION IN THE CONVERSATION, 1 = oldest/topmost match,
    /// `total` = newest/bottom-most. It is still our own approximation, not
    /// SwiftTerm's real search cursor — SwiftTerm's cursor is entirely
    /// internal (SearchService/SearchEngine are not `public`), so there is
    /// no way to read "which match, positionally" back out of SwiftTerm
    /// itself; this is advanced in lockstep with each successful navigation
    /// via `navigateFind`, same as before. It is ALSO built on the
    /// assumption that the FIRST navigation of a fresh search starts from
    /// the bottom of the buffer (the terminal's normal resting position —
    /// see FindBarView's Fix 5b doc comment): a fresh `.up` (searching
    /// backward from the bottom) is defined to land on `total`, the newest
    /// match, and a fresh `.down` on `1`, the oldest. If the user had
    /// scrolled up before opening the find bar, SwiftTerm's actual first
    /// jump may not match that assumption and the displayed number can be
    /// off — the same honest caveat as before this fix, now restated for
    /// the new meaning.
    ///
    /// Before this fix the index counted ORDER OF VISIT instead (`.up`
    /// incremented 1, 2, 3… as the user walked backward through history,
    /// wrapping to 1 at the top; `.down` decremented, wrapping to `total`
    /// at the bottom) — a number that told the user how many jumps they'd
    /// made, never WHERE they were, and that moved in a DIFFERENT direction
    /// each time the search wrapped. That mismatch is what the owner
    /// reported ("la numérotation est bizarre, elle commence au dernier
    /// message de claude, puis descend et ensuite remonte tout en haut").
    ///
    /// SAFETY GUARD: SwiftTerm's own search
    /// (`SearchService.findAll`/`SearchLineCache.translateBufferLineToStringWithWrap`)
    /// stitches soft-wrapped rows into one logical line before matching.
    /// Our own harvest (`harvestBufferLines`) reads each row independently
    /// — verified `BufferLine.isWrapped` is NOT `public` in the vendored
    /// SwiftTerm (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/BufferLine.swift:24`,
    /// declared `var isWrapped: Bool` with no access modifier, i.e.
    /// module-internal), so there is no way to reproduce that stitching
    /// from outside the module. Worst case: a match straddling a wrap is
    /// findable/highlighted by SwiftTerm (`found == true`) but invisible to
    /// our own count (`total == 0`). Showing "no match" in that case would
    /// directly contradict what the user can see highlighted on screen — so
    /// this shows the position as unknown ("…") instead of lying about it.
    static func resolveMatchDisplay(found: Bool, total: Int, previousIndex: Int, direction: FindDirection) -> (text: String, index: Int, total: Int) {
        guard found else {
            return ("no match", 0, 0)
        }
        guard total > 0 else {
            return ("…", 0, 0)
        }
        let nextIndex: Int
        switch direction {
        // .up walks toward OLDER matches — position decreases, wrapping
        // from 1 (oldest) back to `total` (newest). A fresh search
        // (previousIndex == 0) satisfies `<= 1` and lands on `total`, the
        // newest match — what a backward search from the bottom finds first.
        case .up:   nextIndex = previousIndex <= 1 ? total : previousIndex - 1
        // .down walks toward NEWER matches — position increases, wrapping
        // from `total` (newest) back to 1 (oldest). A fresh search
        // (previousIndex == 0) never satisfies `>= total` (total >= 1) and
        // lands on 1, the oldest match — what a forward search from the
        // bottom wraps immediately to.
        case .down: nextIndex = previousIndex >= total ? 1 : previousIndex + 1
        }
        return ("\(nextIndex) / \(total)", nextIndex, total)
    }

    /// v1.5 re-review of 43853ca — the exact text `navigateFind` paints onto
    /// the counter the instant a jump succeeds (`found == true`) but its
    /// count is a cache miss and about to go async (`scheduleMatchCount`).
    /// Pure + static, wrapping `resolveMatchDisplay(found: true, total: 0,
    /// ...)` — the SAME found-but-total-unknown case Finding 2 above
    /// established — rather than a second "…" literal, so the two can never
    /// silently drift apart. `previousIndex`/`direction` are accepted (and
    /// forwarded) purely so this stays a faithful call to
    /// `resolveMatchDisplay`; the `guard total > 0` branch it hits ignores
    /// both and always returns "…" regardless.
    static func scheduledCountPlaceholder(previousIndex: Int, direction: FindDirection) -> String {
        resolveMatchDisplay(found: true, total: 0, previousIndex: previousIndex, direction: direction).text
    }

    /// v1.4.2 task-review Finding 1 — harvest (synchronously, on main — see
    /// `harvestBufferLines`'s doc comment for why) then count (on a
    /// background queue) for a cache-miss navigation. `generation` guards
    /// the eventual `DispatchQueue.main.async` apply against a newer
    /// navigation (or a term/bar clear) having started in the meantime —
    /// same discard-stale-result shape as `refreshContextMeter`.
    private func scheduleMatchCount(term: String, direction: FindDirection, terminalIdentity: ObjectIdentifier) {
        matchCountGeneration += 1
        let generation = matchCountGeneration
        let lines = harvestBufferLines()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let total = MatchCounter.count(term: term, in: lines)
            DispatchQueue.main.async {
                guard let self, self.matchCountGeneration == generation else { return }
                self.harvestCache = HarvestCache(term: term, terminalIdentity: terminalIdentity, lines: lines, total: total, timestamp: Date())
                self.applyMatchDisplay(found: true, total: total, direction: direction)
            }
        }
    }

    /// v1.4.2 task-review Finding 3 — pure derivation of the harvest cap
    /// from the user's configured scrollback (`OpusPreferences.scrollbackLines`,
    /// up to 200_000) instead of the old hardcoded 50_000, which silently
    /// undercounted matches beyond row 50k while SwiftTerm could still
    /// navigate to them. `+1_000` headroom covers the terminal's own
    /// on-screen rows sitting atop the scrollback proper; the 200_000
    /// ceiling bounds worst-case work regardless of the preference value
    /// (matches `OpusPreferences.scrollbackLines`'s own clamp ceiling, so
    /// this can never exceed what the buffer itself retains anyway). Pure +
    /// static so it's unit-testable without a live terminal/preferences
    /// singleton.
    static func harvestCap(scrollbackLines: Int) -> Int {
        min(200_000, scrollbackLines + 1_000)
    }

    /// Fix 2 (v1.4.2) — harvest the ACTIVE terminal's buffer as plain-text
    /// lines via SwiftTerm's PUBLIC API (`getScrollInvariantLine` +
    /// `translateToString`), feeding `MatchCounter`. SwiftTerm's own match
    /// counting (`SearchService.findAll`) is `internal` — not usable from
    /// here — so this reads the same buffer through the public surface
    /// instead: starting at row 0, walking forward until
    /// `getScrollInvariantLine` returns nil. v1.4.2 task-review Finding 3:
    /// capped via `harvestCap(scrollbackLines:)` (was a hardcoded 50_000)
    /// so the cap tracks the user's actual configured scrollback instead of
    /// silently under-counting past it.
    ///
    /// DELIBERATELY STAYS ON MAIN (task-review Finding 1 deviation): the
    /// literal brief asked for "harvest+count" to both move to a background
    /// queue, but `getScrollInvariantLine`/`translateToString` read live
    /// `BufferLine` objects — `class` instances backed by a raw
    /// `UnsafeMutableBufferPointer<CharData>` with NO locking anywhere in
    /// SwiftTerm (checked: no `NSLock`/`os_unfair_lock`/actor isolation on
    /// `Terminal`/`Buffer`/`BufferLine`). Every `.feed()` call in this
    /// codebase is funneled through `DispatchQueue.main.async` specifically
    /// because of this (see `main.swift`'s `dataReceived`/`TabPane.makeShared`'s
    /// subscription) — Claude Code's own TUI repaints regions above the
    /// cursor via ANSI cursor movement, i.e. existing `BufferLine`s DO get
    /// mutated in place, not just appended to. Reading that same storage
    /// from a background thread while `.feed()` concurrently mutates it on
    /// main would be a real memory-safety hazard, not a style nitpick. So
    /// only THIS function (the cheap, ~21ms-at-10k-rows part) stays
    /// synchronous on main; `MatchCounter.count()` — a pure function over
    /// the already-copied `[String]` this returns, safe to hand to another
    /// thread — is what actually moves to background (`scheduleMatchCount`),
    /// which is also where the worse-scaling cost lives (84ms of the 105ms
    /// total at 10k rows, ~420ms of the 535ms total at the old 50k cap).
    private func harvestBufferLines() -> [String] {
        guard let term = activeTerminal?.getTerminal() else { return [] }
        let cap = Self.harvestCap(scrollbackLines: OpusPreferences.shared.scrollbackLines)
        var lines: [String] = []
        var row = 0
        while row < cap, let line = term.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true))
            row += 1
        }
        return lines
    }

    func toggleFindBar() {
        if let bar = findBar {
            bar.removeFromSuperview()
            findBar = nil
            activeTerminal?.clearSearch()
            if let t = activeTerminal { window?.makeFirstResponder(t) }
            return
        }
        let bar = FindBarView(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        // Fix 5b (v1.4.1): Enter (onSearchUp) → SwiftTerm's findPrevious
        // (backward through the buffer, toward older/earlier lines — "up").
        // Shift+Enter (onSearchDown) → findNext (toward the bottom). Fix 2
        // (v1.4.2): arrow keys land on these same two callbacks (see
        // FindBarView.control(_:textView:doCommandBy:)); both now route
        // through navigateFind so the match counter tracks every path.
        bar.onSearchUp = { [weak self] term in self?.navigateFind(term: term, direction: .up) }
        bar.onSearchDown = { [weak self] term in self?.navigateFind(term: term, direction: .down) }
        bar.onClose = { [weak self] in self?.toggleFindBar() }
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 60),
            bar.widthAnchor.constraint(equalToConstant: 320),
            bar.heightAnchor.constraint(equalToConstant: 30),
        ])
        window?.makeFirstResponder(bar.field)
        findBar = bar
    }

    /// Repeat the last find-bar search UPWARD (older/earlier lines) —
    /// Cmd+G. Fix 5b (v1.4.1) rename from findNextInActivePane: the method
    /// now calls SwiftTerm's findPrevious, so the old "next" name would
    /// have been actively misleading about which direction it searches.
    /// Fix 2 (v1.4.2): routes through navigateFind so Cmd+G keeps the match
    /// counter current too, not just the bar's own Enter/arrows.
    func searchUpInActivePane()   { if !lastSearchTerm.isEmpty { navigateFind(term: lastSearchTerm, direction: .up) } }
    /// Repeat the last find-bar search DOWNWARD (toward the bottom) —
    /// Cmd+Shift+G. Renamed from findPreviousInActivePane for the same
    /// reason as searchUpInActivePane above. Fix 2 (v1.4.2): same
    /// navigateFind routing as searchUpInActivePane.
    func searchDownInActivePane() { if !lastSearchTerm.isEmpty { navigateFind(term: lastSearchTerm, direction: .down) } }

    /// Claude Code renders its prompt line with the "❯" glyph — jumping
    /// between prompts is a search in disguise (SwiftTerm's public findNext/
    /// findPrevious scroll to the result; scrollTo(row:) is internal, so the
    /// search engine is the only public scrolling road).
    func jumpToPreviousPrompt() { _ = activeTerminal?.findPrevious("❯ ") }
    func jumpToNextPrompt()     { _ = activeTerminal?.findNext("❯ ") }

    /// True while the find bar's field (or its field editor) owns focus.
    /// The key monitors must not act on the live panes in that state.
    ///
    /// Verified empirically (small AppKit harness outside the test target,
    /// since XCTest can't reliably drive real firstResponder/field-editor
    /// state): starting an edit on an NSSearchField makes the window's
    /// firstResponder the shared field-editor NSTextView, and that view IS
    /// nested inside the search field's view hierarchy for the duration of
    /// editing (AppKit inserts it as a subview to render the caret/selection).
    /// So `isDescendant(of: bar)` alone catches both "the field itself has
    /// focus" and "the field editor is actively editing it" — no fallback
    /// to `bar.field.currentEditor()` needed, though that also held true
    /// in the same harness.
    var findBarHasFocus: Bool {
        guard let bar = findBar, let fr = window?.firstResponder as? NSView else { return false }
        return fr.isDescendant(of: bar)
    }

    /// The find bar targets the active pane; when that context changes the
    /// bar must go with it, or blind keystrokes land in a live session.
    private func closeFindBarIfOpen() {
        guard findBar != nil else { return }
        toggleFindBar()   // removes the bar, clears the search, restores focus
    }

    /// Live-apply font changes to every pane. Cheap + idempotent: every pref
    /// write fires this, so compare before assigning (SwiftTerm's font setter
    /// recalculates cell metrics and triggers a resize cascade).
    @objc private func preferencesDidChange() {
        let newFont = OpusPreferences.shared.resolvedTerminalFont()
        for paneList in tabPanes {
            for pane in paneList {
                let t = pane.terminal
                if t.font.fontName != newFont.fontName || t.font.pointSize != newFont.pointSize {
                    t.font = newFont
                }
            }
        }
        // Cross-surface sync: picking a permission mode in ONE shared-tab-0
        // surface (e.g. panelAndMain's panel) writes the pref, which posts
        // this same notification to every container — refresh so the OTHER
        // surface's shield menu checkmark follows along. No-ops on containers
        // without a shield button (refreshShieldButton guards on shieldButton
        // being nil).
        refreshShieldButton()
    }

    private func bootstrapFirstTab() {
        if useSharedTab0 {
            ClaudeBackend.shared.startIfNeeded()
            let pane0 = TabPane.makeShared(frame: terminalArea.bounds, panel: nil, container: self)
            styleTerminal(pane0.terminal)
            terminalArea.addSubview(pane0.terminal)
            tabs.append(pane0.terminal)
            tabPanes.append([pane0])
            tabActivePaneIndex.append(0)
            tabTitles.append("Claude")
            recordPendingSpawn(pane0)
            // Lot 3, Task 6: startIfNeeded() no-ops when ANOTHER container
            // already triggered the spawn (ClaudeBackend.shared is a
            // singleton — MainTerminalWindow's container is built lazily,
            // often well after the panel's own bootstrap already spawned and
            // its .claudeBackendDidSpawn notification already fired and is
            // long gone). This container's own `sharedBackendDidSpawn`
            // observer (registered further down in init, after
            // bootstrapFirstTab runs) only catches FUTURE spawns — it can't
            // retroactively see one that already happened. Reading
            // currentSessionId directly here, synchronously, closes that gap
            // for every container regardless of construction order.
            if let sessionId = ClaudeBackend.shared.currentSessionId {
                ClaudeStateStore.shared.bindSession(paneToken: ObjectIdentifier(pane0.terminal), sessionId: sessionId)
            }
        } else {
            let pane0 = TabPane.makePrivate(frame: terminalArea.bounds, panel: nil, container: self)
            styleTerminal(pane0.terminal)
            terminalArea.addSubview(pane0.terminal)
            pane0.start()
            tabs.append(pane0.terminal)
            tabPanes.append([pane0])
            tabActivePaneIndex.append(0)
            tabTitles.append("Claude")
            recordPendingSpawn(pane0)
            bindKnownSession(pane0)
        }
    }

    // MARK: Public API (called by the host)

    var activePane: TabPane? {
        guard tabPanes.indices.contains(activeTabIndex) else { return nil }
        let panes = tabPanes[activeTabIndex]
        if let fr = window?.firstResponder as? TerminalView,
           let p = panes.first(where: { $0.terminal === fr }) { return p }
        let saved = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
        guard panes.indices.contains(saved) else { return panes.first }
        return panes[saved]
    }

    var activeTerminal: TerminalView? { activePane?.terminal }

    func spawnNewTab() {
        let pane = TabPane.makePrivate(frame: terminalFrame(), panel: nil, container: self)
        styleTerminal(pane.terminal)
        pane.terminal.isHidden = true
        terminalArea.addSubview(pane.terminal)
        pane.start()
        tabs.append(pane.terminal)
        tabPanes.append([pane])
        tabActivePaneIndex.append(0)
        tabTitles.append("Claude")
        recordPendingSpawn(pane)
        bindKnownSession(pane)
        switchTab(to: tabs.count - 1)
    }

    func closeActivePane() {
        guard let pane = activePane else { return }
        closePane(pane)
    }

    /// Restart the session backing the ACTIVE pane: the shared backend when
    /// the shared pane has focus, that pane's private claude otherwise.
    func restartActiveSession() {
        guard let pane = activePane else {
            ClaudeBackend.shared.restart(resume: false)
            return
        }
        closeFindBarIfOpen()
        if let wrapper = pane.wrapper {
            hideDeadOverlay(forPane: pane)   // stale overlay would eat the fresh TUI
            wrapper.restartFresh()
        } else {
            ClaudeBackend.shared.restart(resume: false)
        }
    }

    // MARK: Tab index arithmetic

    /// Pure index arithmetic for tab removal: shift down when a lower-index
    /// tab disappears, clamp when the active tab itself (or the tail) went.
    static func activeTabIndexAfterClosing(_ closed: Int, active: Int, newCount: Int) -> Int {
        var a = active
        if closed < a { a -= 1 }
        if a >= newCount { a = max(0, newCount - 1) }
        return a
    }

    func closePane(_ pane: TabPane, force: Bool = false) {
        guard let tabIdx = tabPanes.firstIndex(where: { panes in panes.contains(where: { $0 === pane }) }),
              let paneIdx = tabPanes[tabIdx].firstIndex(where: { $0 === pane }) else { return }

        // Don't let the user kill the shared pane in tab 0 via Cmd+W — that's
        // the session mirrored with Terminal.app via opus-attach. `force:true`
        // bypass is reserved for internal lifecycle (shared backend death with
        // other tabs alive).
        if tabIdx == 0 && pane.wrapper == nil && !force { return }

        // Both guards above have resolved (a pane WILL actually close from
        // here on) — safe to close the bar without leaving a stray side
        // effect on either early-return path.
        closeFindBarIfOpen()
        // Cockpit (Lot 3, Task 7): the pane set is about to change — disarm
        // broadcast unconditionally (simplest correct rule; covers every
        // call site, including `handlePrivateTabTerminated`'s closePane
        // calls for a pane dying in a BACKGROUND tab, not just Cmd+W on the
        // active one). Runs before the pane is actually removed below, so
        // if it belonged to the active tab, refreshBroadcastBorders still
        // sees it in `tabPanes[activeTabIndex]` and clears its border too.
        broadcastArmed = false

        pane.terminate()

        let view = pane.terminal
        let parent = view.superview
        // Order matters: drop from arranged list first (NSSplitView keeps its
        // internal constraints in sync), then detach from the view hierarchy,
        // then redistribute remaining panes evenly.
        if let parentSplit = parent as? NSSplitView {
            parentSplit.removeArrangedSubview(view)
            view.removeFromSuperview()
            parentSplit.adjustSubviews()
        } else {
            view.removeFromSuperview()
        }
        tabPanes[tabIdx].remove(at: paneIdx)

        if tabPanes[tabIdx].isEmpty {
            // The tab itself has nothing left to show — drop it.
            tabs[tabIdx].removeFromSuperview()
            tabs.remove(at: tabIdx)
            tabPanes.remove(at: tabIdx)
            tabActivePaneIndex.remove(at: tabIdx)
            tabTitles.remove(at: tabIdx)
            activeTabIndex = Self.activeTabIndexAfterClosing(
                tabIdx, active: activeTabIndex, newCount: tabs.count)
            switchTab(to: activeTabIndex)
        } else {
            // Refocus a neighbor pane in the same tab.
            let newIdx = min(paneIdx, tabPanes[tabIdx].count - 1)
            tabActivePaneIndex[tabIdx] = newIdx
            if activeTabIndex == tabIdx {
                window?.makeFirstResponder(tabPanes[tabIdx][newIdx].terminal)
            }
            refreshActiveTabTitle()
            // The tab's active pane just changed (the closed split may have
            // been the one carrying the dot) — recompute its dot from the
            // now-focused sibling's session instead of leaving the stale one
            // painted until some unrelated future event happens to repaint it.
            refreshTabBarStates()
        }
    }

    func splitActivePane(vertical: Bool) {
        guard let oldPane = activePane,
              tabPanes.indices.contains(activeTabIndex) else { return }
        closeFindBarIfOpen()
        // Cockpit (Lot 3, Task 7): the pane set is about to change — disarm
        // broadcast unconditionally, same rule as `closePane`.
        broadcastArmed = false

        let oldView = oldPane.terminal
        let parent = oldView.superview
        // Inherit oldView's frame so the new pane never starts at zero size —
        // NSSplitView would briefly hand a 0×0 child to SwiftTerm otherwise,
        // and its size-change calc can produce negative cols/rows during that
        // first layout pass (which is what makes the UInt16 conversion crash).
        let newPane = TabPane.makePrivate(frame: oldView.frame, panel: nil, container: self)
        styleTerminal(newPane.terminal)
        newPane.start()
        recordPendingSpawn(newPane)
        bindKnownSession(newPane)

        if let parentSplit = parent as? NSSplitView, parentSplit.isVertical == vertical {
            // Same axis — extend the existing split.
            let idx = (parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0) + 1
            parentSplit.insertArrangedSubview(newPane.terminal, at: idx)
            parentSplit.adjustSubviews()
        } else if let parentSplit = parent as? NSSplitView {
            // Different axis — wrap old pane in a perpendicular split. NSSplitView
            // doesn't auto-redistribute when we remove and re-insert: removing
            // newPane1 lets sharedTerminal stretch to full width, then the inner
            // gets 0 width on insertion (looks like "Cmd+Shift+D cancelled Cmd+D").
            // adjustSubviews() forces an even split again.
            let idx = parentSplit.arrangedSubviews.firstIndex(of: oldView) ?? 0
            parentSplit.removeArrangedSubview(oldView)
            oldView.removeFromSuperview()
            let inner = OpusSplitView(frame: oldView.frame)
            inner.isVertical = vertical
            inner.addArrangedSubview(oldView)
            inner.addArrangedSubview(newPane.terminal)
            parentSplit.insertArrangedSubview(inner, at: idx)
            parentSplit.adjustSubviews()
            inner.adjustSubviews()
        } else {
            // Old view is the tab's top-level — promote it inside a new NSSplitView.
            let root = OpusSplitView(frame: oldView.frame)
            root.isVertical = vertical
            root.autoresizingMask = oldView.autoresizingMask
            oldView.removeFromSuperview()
            root.addArrangedSubview(oldView)
            root.addArrangedSubview(newPane.terminal)
            terminalArea.addSubview(root)
            tabs[activeTabIndex] = root
            root.adjustSubviews()
        }

        tabPanes[activeTabIndex].append(newPane)
        tabActivePaneIndex[activeTabIndex] = tabPanes[activeTabIndex].count - 1
        window?.makeFirstResponder(newPane.terminal)
        refreshActiveTabTitle()
    }

    func switchTab(to index: Int) {
        guard tabs.indices.contains(index) else { return }
        closeFindBarIfOpen()
        // Cockpit (Lot 3, Task 7): any tab change disarms broadcast. This
        // MUST run before `activeTabIndex` is reassigned below — disarming
        // (broadcastArmed's didSet → refreshBroadcastBorders) needs to see
        // the OLD activeTabIndex so it clears the border on the tab being
        // LEFT, not the one being switched to.
        broadcastArmed = false

        // Before we leave the current tab, remember which pane has focus so we
        // can restore it next time the user comes back.
        let prev = activeTabIndex
        if tabPanes.indices.contains(prev),
           let fr = window?.firstResponder as? TerminalView,
           let paneIdx = tabPanes[prev].firstIndex(where: { $0.terminal === fr }) {
            tabActivePaneIndex[prev] = paneIdx
        }

        for (i, view) in tabs.enumerated() { view.isHidden = (i != index) }
        activeTabIndex = index
        refreshActiveTabTitle()
        updateTabIndicator()

        guard tabPanes.indices.contains(index) else { return }
        let savedIdx = tabActivePaneIndex.indices.contains(index) ? tabActivePaneIndex[index] : 0
        let panes = tabPanes[index]
        guard panes.indices.contains(savedIdx) else { return }
        let pane = panes[savedIdx]
        window?.makeFirstResponder(pane.terminal)

        // The user is now looking at this pane — a `.done`/`.needsInput`
        // dot on it has been "read"; clear it back to idle.
        if let sessionId = sessionId(for: pane) {
            ClaudeStateStore.shared.markSeen(sessionId: sessionId)
        }

        // Shared pane → push its dimensions back to the broadcast PTY.
        if pane.wrapper == nil {
            ClaudeBackend.shared.setPrimarySize(
                cols: UInt16(pane.terminal.getTerminal().cols),
                rows: UInt16(pane.terminal.getTerminal().rows)
            )
        }

        // The active tab just changed — refresh the context meter now
        // rather than leaving the PREVIOUS tab's stale reading on screen
        // for up to 10s (the periodic timer alone would otherwise let a
        // just-switched-to tab show a flatly wrong bar/tooltip). Deviation
        // beyond the controller spec's literal "10s Timer" wording, kept
        // because a stale-tab bar is a real, easily-hit correctness gap,
        // not a hypothetical.
        refreshContextMeter()
        // Same reasoning for the todo drawer (v1.6 backlog Task 3): without
        // this, switching from a tab bound to session A to a tab bound to
        // session B while the drawer is open would keep showing A's tasks
        // for up to 5s. No-ops when the drawer is closed.
        refreshTodoDrawer()
    }

    /// True when `text`, once whitespace-trimmed, is nothing but the "❯ "
    /// prompt marker `jumpToPreviousPrompt`/`jumpToNextPrompt` search for
    /// (Cmd+Up/Down). Static + pure so it's unit-testable without a live
    /// TerminalView/selection.
    static func isPromptMarkerSelection(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == "❯"
    }

    /// FINDING (a), v1.6 backlog task-1 fix round: `deliver(bytes:)` writes
    /// raw UTF-8 straight to the PTY, so every `\n` inside pasted (or
    /// palette-inserted, or Cmd+Ctrl+S-sent) multi-line text lands exactly
    /// like the user pressing Return between each line — claude submits at
    /// the first newline instead of receiving the whole block. Real
    /// terminals avoid this with the "bracketed paste" protocol (xterm mode
    /// 2004): wrap the pasted text in `ESC[200~` / `ESC[201~` so a
    /// bracketed-paste-aware reader (claude's TUI) knows the newlines inside
    /// are DATA, not keystrokes, and doesn't submit until the user actually
    /// presses Return themselves afterward.
    ///
    /// `enabled` must be the TARGET terminal's own, currently-negotiated
    /// `SwiftTerm.Terminal.bracketedPasteMode` (set true/false by the CSI
    /// `?2004h`/`?2004l` sequences the target program sends when it wants
    /// paste mode) — never a hardcoded `true`. Inventing the markers when
    /// the target never asked for them would land `ESC[200~`/`ESC[201~` as
    /// literal garbage characters in that pane instead of being interpreted
    /// as paste boundaries. `enabled == false` therefore returns the plain
    /// UTF-8 bytes, unwrapped — byte-for-byte what `deliver(bytes:)` always
    /// sent, so disabled targets see no behavior change from this fix.
    ///
    /// Sanitizes exactly one thing out of `text` before wrapping: a literal
    /// `ESC[201~` (the END-paste marker) embedded IN the payload. The
    /// bracketed-paste wire protocol has no way to escape that exact byte
    /// sequence — ANY bracketed-paste-aware reader ends the paste at the
    /// FIRST `ESC[201~` it sees, whether that's our real closing marker or
    /// one that happens to already be sitting inside the text (e.g. a
    /// terminal transcript the user previously copied, or a stray history
    /// entry). Left in, it would prematurely close our wrapper and dump
    /// everything after it — INCLUDING the real trailing `ESC[201~` and any
    /// following keystrokes — as live, unwrapped input, which can include a
    /// literal Return: exactly the auto-submit bug this function exists to
    /// close, just relocated mid-paste instead of at the first `\n`. No
    /// other byte is touched — a bare, unpaired ESC is left exactly as
    /// typed/pasted. That is LESS aggressive than what mainstream terminal
    /// emulators actually do on paste: xterm's `disallowedPasteControls`
    /// filters ESC by default, Alacritty strips every `\x1b` byte from a
    /// bracketed paste, and VTE-based terminals filter C0 controls outright.
    /// Opus deliberately does none of that — pasting an ANSI-colored
    /// transcript is a normal thing to do here — and special-cases only this
    /// one 6-byte terminator, because it's indistinguishable, on the wire,
    /// from our own closing marker.
    ///
    /// Fix round (finding F1): stripping the marker is done to a FIXPOINT —
    /// a single `replacingOccurrences` pass is not enough, because removing
    /// one match can splice the surrounding bytes into a NEW match.
    /// `"\u{1B}[20" + "\u{1B}[201~" + "1~"` demonstrates it: one pass removes
    /// the middle (real) occurrence and concatenates its neighbors into
    /// `"\u{1B}[201~"` — a freshly-assembled end marker that a single pass
    /// leaves behind. Looping until `payload` no longer contains the marker
    /// closes that hole; each pass can only ever shrink `payload`, so this
    /// always terminates.
    static func bracketedPaste(_ text: String, enabled: Bool) -> [UInt8] {
        guard enabled else { return Array(text.utf8) }
        let endMarker = "\u{1B}[201~"
        var payload = text
        while payload.contains(endMarker) {
            payload = payload.replacingOccurrences(of: endMarker, with: "")
        }
        let start: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]  // ESC [ 2 0 0 ~
        let end: [UInt8]   = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]  // ESC [ 2 0 1 ~
        return start + Array(payload.utf8) + end
    }

    func copySelectionToPasteboard() {
        guard let terminal = activeTerminal else { return }
        let selection = terminal.getSelection()
        // Cockpit (Lot 3, sticky-selection fix): Cmd+Up/Down prompt jump
        // does a findPrevious/findNext("❯ ") under the hood, which leaves
        // that match selected — SwiftTerm never auto-clears a selection on
        // streaming output, so it sticks until the user clicks the
        // terminal. Without the isPromptMarkerSelection check, every Cmd+C
        // after a jump would copy the prompt glyph instead of sending the
        // Ctrl-C interrupt. A real user selection never trims down to
        // exactly "❯", so this can't shadow an intentional copy.
        guard let text = selection, !text.isEmpty, !Self.isPromptMarkerSelection(text) else {
            // Cockpit (Lot 3, Task 7 fix round 1): route the empty-selection
            // interrupt through `deliver(bytes:)` so it becomes a
            // bulk-interrupt of every pane in the active tab while armed,
            // instead of silently hitting only this one.
            deliver(bytes: ArraySlice<UInt8>([0x03]))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteFromPasteboard() {
        guard activePane != nil else { return }
        let pb = NSPasteboard.general
        // Files copied/dragged from Finder carry their POSIX path under the
        // file-URL type, while `.string` is only the display name (e.g. "Reports").
        // Insert the full shell-quoted path(s), matching Terminal.app.
        if let paths = Self.filePathsString(from: pb) {
            sendToActivePane(paths)
            return
        }
        guard let str = pb.string(forType: .string), !str.isEmpty else { return }
        sendToActivePane(str)
    }

    // MARK: Pasteboard / file-path helpers

    /// Inject text into the active pane's PTY (private wrapper or shared
    /// backend) — or, while broadcast is armed, into every pane of the
    /// active tab. Covers both `pasteFromPasteboard` (Cmd+V) and Finder
    /// drag-drop (`performDragOperation` below), which is exactly what a
    /// user arming broadcast to paste one prompt into N sessions expects.
    ///
    /// FINDING (a) fix round: routes through `deliverAsPaste`, NOT
    /// `deliver(bytes:)` — text landing here always arrived as one paste-like
    /// operation (Cmd+V, a Finder drop, a palette pick, Cmd+Ctrl+S), never as
    /// individual keystrokes, so it always deserves bracketed-paste wrapping
    /// when the target has asked for it. See `deliverAsPaste`'s doc comment
    /// for why this can't just call `deliver(bytes:)` with precomputed bytes.
    private func sendToActivePane(_ text: String) {
        deliverAsPaste(text)
    }

    /// Public entry point for PromptPalettePanel (Cmd+Shift+P, task-1 of the
    /// v1.6 backlog): insert a picked prompt into the active pane WITHOUT a
    /// trailing return — the user reviews and submits it themselves, same as
    /// a plain paste. Reuses `sendToActivePane` verbatim rather than
    /// duplicating its `deliverAsPaste` call, so this gets the exact same
    /// broadcast-arming AND bracketed-paste behavior as Cmd+V/Finder-drop for
    /// free: while broadcast is armed, the prompt lands in every pane of the
    /// active tab, not just the one on screen, and each pane decides for
    /// itself (via its own `bracketedPasteMode`) whether to wrap.
    func insertIntoActivePane(_ text: String) {
        sendToActivePane(text)
    }

    /// Cockpit (Lot 3, Task 7 fix round 1) — the delivery point for input
    /// that does NOT arrive as a keystroke and must NEVER be interpreted as
    /// pasted text: the empty-selection Ctrl-C interrupt in
    /// `copySelectionToPasteboard` is the ONLY caller left after the FINDING
    /// (a) fix round (below) split paste/drop/palette/Cmd+Ctrl+S off into
    /// `deliverAsPaste`. An interrupt is a single control byte (0x03), not a
    /// paste — bracketed-paste-wrapping it would be nonsensical (and could
    /// even suppress the interrupt if the reader treated it as paste
    /// content instead of a signal-generating key), so this stays exactly as
    /// it was: raw bytes, straight to the target(s), no wrapping decision at
    /// all. Broadcasts to every pane of the active tab when armed, otherwise
    /// single-target routes to the active pane (private wrapper, or the
    /// shared backend as a fallback when there's no active pane at all).
    ///
    /// This is a SEPARATE chokepoint from the keystroke path
    /// (`send(source:data:)` / `interceptForBroadcast`, driven by
    /// `TerminalViewDelegate`): paste/drop/interrupt never go through a
    /// `TerminalViewDelegate` — they call straight into the active pane's
    /// wrapper/backend — which is exactly why they used to bypass the
    /// broadcast check entirely (Fix round 1).
    private func deliver(bytes: ArraySlice<UInt8>) {
        if broadcastArmed {
            broadcast(data: bytes)
        } else if let wrapper = activePane?.wrapper {
            wrapper.sendInput(bytes: bytes)
        } else {
            ClaudeBackend.shared.send(data: bytes)
        }
    }

    /// FINDING (a), v1.6 backlog task-1 fix round — the paste-specific
    /// counterpart to `deliver(bytes:)` above, and the delivery point for
    /// EVERYTHING that lands text as one paste-like operation: routed here
    /// via `sendToActivePane` from `pasteFromPasteboard` (Cmd+V),
    /// `performDragOperation` (Finder drop), and `insertIntoActivePane`
    /// (the Cmd+Shift+P palette and the Cmd+Ctrl+S "send clipboard" hotkey).
    /// Deliberately does NOT touch the empty-selection Ctrl-C interrupt in
    /// `copySelectionToPasteboard` — see `deliver(bytes:)`'s doc comment for
    /// why an interrupt must never be wrapped.
    ///
    /// Can't just compute wrapped bytes once and hand them to
    /// `deliver(bytes:)`/`broadcast(data:)`: `deliver(bytes:)` takes bytes
    /// that are already final, but bracketed-paste wrapping depends on the
    /// TARGET's `bracketedPasteMode` — which, while broadcast is armed, is a
    /// property of EACH pane individually (point 5 of the fix brief). Every
    /// pane owns its own SwiftTerm `Terminal`, so every pane negotiates mode
    /// 2004 independently: one pane's claude can be sitting at a prompt with
    /// paste mode on while a sibling pane is mid-transition (spawning,
    /// restarting, or simply a claude build that hasn't sent `CSI ?2004h`
    /// yet) with the mode still off. Computing `enabled` once from
    /// `activeTerminal`/`activePane` and reusing that one decision for every
    /// pane would silently mis-wrap any pane whose mode disagrees with the
    /// active one:
    ///   - wrapping bytes meant for a mode-off pane makes `ESC[200~`/
    ///     `ESC[201~` show up as literal garbage characters in that pane;
    ///   - NOT wrapping bytes meant for a mode-on pane reintroduces the
    ///     exact submit-at-first-newline bug this fix exists to close, just
    ///     for that one pane.
    /// So this re-derives the same "broadcast when armed, else single
    /// active-pane target, else the shared backend with no terminal to
    /// query" shape `deliver(bytes:)` uses, but asks each TARGET pane's own
    /// `terminal.getTerminal().bracketedPasteMode` — via the per-pane
    /// `broadcast(bytesForPane:)` overload below for the armed case, and
    /// directly against `pane` for the single-target case — instead of
    /// asking once up front.
    private func deliverAsPaste(_ text: String) {
        guard !text.isEmpty else { return }
        if broadcastArmed {
            broadcast { pane in
                let enabled = pane.terminal.getTerminal().bracketedPasteMode
                return ArraySlice(Self.bracketedPaste(text, enabled: enabled))
            }
        } else if let pane = activePane {
            let enabled = pane.terminal.getTerminal().bracketedPasteMode
            let bytes = ArraySlice(Self.bracketedPaste(text, enabled: enabled))
            if let wrapper = pane.wrapper {
                wrapper.sendInput(bytes: bytes)
            } else {
                ClaudeBackend.shared.send(data: bytes)
            }
        } else {
            // No resolvable pane means no terminal to query — same edge
            // case `deliver(bytes:)` hits when `activePane` is nil (e.g. no
            // tab has finished bootstrapping yet). With no target to ask,
            // there's no way to know whether wrapping is safe, so this
            // matches `deliver(bytes:)`'s always-unwrapped fallback exactly:
            // plain UTF-8 bytes, straight to the shared backend.
            ClaudeBackend.shared.send(data: ArraySlice(Array(text.utf8)))
        }
    }

    /// Single-quote a POSIX path so it survives the shell verbatim (spaces,
    /// parentheses, etc.). Embedded single quotes become the `'\''` idiom.
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// If the pasteboard holds file URLs (Finder copy/drag), return their
    /// shell-quoted POSIX paths joined by spaces. `nil` when no file URLs.
    ///
    /// Not `private` (Send to Claude, v1.6 backlog Task 2) — `sendClipboardToClaude()`
    /// reuses this verbatim to read `NSPasteboard.general` in the same order as
    /// `pasteFromPasteboard` (file URLs first, then plain string) rather than
    /// re-deriving the same file-URL-detection + shell-quoting logic a second time.
    ///
    /// `static` (palette fix round): reading a pasteboard never depended on a
    /// container instance, and `sendClipboardToClaude()` had to resolve one
    /// JUST to call this — which is exactly the resolution now living in
    /// `AppDelegate.insertIntoActiveClaude`. Static lets that caller read the
    /// clipboard first and hand the payload to the single shared
    /// resolve-and-insert helper, instead of keeping a second copy of the
    /// resolution rules alive next to it.
    static func filePathsString(from pasteboard: NSPasteboard) -> String? {
        guard let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return nil }
        return urls.map { shellQuote($0.path) }.joined(separator: " ")
    }

    // MARK: Drag & drop (Finder files → path in the terminal)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.filePathsString(from: sender.draggingPasteboard) != nil ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        Self.filePathsString(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let paths = Self.filePathsString(from: sender.draggingPasteboard) else { return false }
        // Trailing space so the next typed argument doesn't glue onto the path.
        sendToActivePane(paths + " ")
        return true
    }

    func refreshActiveTabTitle() {
        guard tabPanes.indices.contains(activeTabIndex),
              tabActivePaneIndex.indices.contains(activeTabIndex) else { return }
        let idx = tabActivePaneIndex[activeTabIndex]
        let panes = tabPanes[activeTabIndex]
        guard panes.indices.contains(idx) else { return }
        tabTitles[activeTabIndex] = panes[idx].title
        tabBar.titles = tabTitles
    }

    func updateTabIndicator() {
        tabBar.tabCount = tabs.count
        tabBar.activeIndex = activeTabIndex
        tabBar.titles = tabTitles
        refreshTabBarStates()
        // Show the bar only when 2+ tabs; shrink terminalArea to make room.
        let showBar = tabs.count > 1
        tabBar.isHidden = !showBar
        tabBar.alphaValue = showBar ? 1 : 0
        tabBarHeightConstraint.constant = showBar ? 26 : 0
        // Room reserved above terminalArea's bottom edge for the status
        // rail (see railBottomConstraint below) so the terminal never draws
        // over it. Broken into named CGFloat constants — the compiler
        // choked ("unable to type-check in reasonable time") on the
        // arithmetic-inside-ternary form.
        //
        // Task 3 (visual harmonization): reserved allocation grows from 6 →
        // 15 — the strip itself is no longer the 4pt ContextMeterBar but
        // StatusRailView, whose intrinsicContentSize (the 10pt monospaced-
        // digit readout label's own height) measures 13pt (see
        // task-2-report.md's layout arithmetic; also reproduced locally: an
        // `NSTextField(labelWithString:)` in
        // `.monospacedDigitSystemFont(ofSize: 10, weight: .regular)` reports
        // `intrinsicContentSize.height == 13.0`). Same "2pt breathing room
        // above the strip" term as before (established Fix 3, v1.4.2),
        // 2 + 13 = 15 replacing the old 2 + 4 = 6. The rail's own bottom-edge
        // position (railBottomShown/Hidden just below) is a separate,
        // UNCHANGED concern — same floor the old meter used — it fixes
        // where the strip's floor sits, not how tall it is, so those two
        // constants don't need to move for a height-only change: growing the
        // reserved allocation by the same +9 (13 - 4) that the rail grew by
        // versus the old meter preserves the exact gap between terminalArea's
        // bottom edge and the strip's top edge in BOTH states (shown: 10pt,
        // hidden: 12pt — unchanged from before this task), and the rail's
        // unchanged floor preserves the exact gap from the strip's bottom
        // edge down to the tab bar in both states too (shown: 18pt, hidden:
        // 12pt — also unchanged).
        let terminalAreaBottomShown: CGFloat = -59   // -(14 + 26 + 4 + 15)
        let terminalAreaBottomHidden: CGFloat = -29  // -(14 + 15)
        terminalAreaBottomConstraint.constant = showBar ? terminalAreaBottomShown : terminalAreaBottomHidden
        // Todo drawer (v1.6 backlog Task 3): own bottom constraint, switched
        // in lockstep with terminalAreaBottomConstraint using the EXACT SAME
        // two constants above (not a drawer-specific pair) — the drawer's
        // bottom edge must always land at the same y-position as
        // terminalArea's own bottom edge, which this arithmetic already
        // keeps clear of the rail/tab-bar band in both states. See
        // buildSubviews()'s doc comment on todoDrawerBottomConstraint.
        todoDrawerBottomConstraint.constant = showBar ? terminalAreaBottomShown : terminalAreaBottomHidden
        // Artifacts drawer: identical treatment, same two constants, same
        // reasoning as todoDrawerBottomConstraint immediately above — see
        // buildSubviews()'s doc comment on artifactsDrawerBottomConstraint.
        artifactsDrawerBottomConstraint.constant = showBar ? terminalAreaBottomShown : terminalAreaBottomHidden
        // Status rail: own constant, switched in lockstep with the two
        // above — see buildSubviews' doc comment on railBottomConstraint for
        // why this can't just track tabBar.topAnchor the way it used to.
        // Values UNCHANGED from the old contextMeterBottomShown/Hidden — the
        // rail's floor doesn't move, only its height (and therefore the
        // terminalArea reservation above) changed. See this function's own
        // doc comment above for the gap arithmetic this preserves.
        let railBottomShown: CGFloat = -36   // -(8 + 26 + 2)
        let railBottomHidden: CGFloat = -4
        railBottomConstraint.constant = showBar ? railBottomShown : railBottomHidden
        tabBar.needsDisplay = true
        layoutSubtreeIfNeeded()
    }

    // MARK: Cockpit — pane↔session binding, tab-bar dots, precise notifications

    /// Register a just-spawned pane with the GLOBAL binding registry
    /// (`ClaudeStateStore`, shared by every TerminalContainerView — see its
    /// doc comment for why this moved out of per-container storage). Called
    /// from every pane-spawn call site: bootstrapFirstTab's two branches,
    /// spawnNewTab, splitActivePane.
    private func recordPendingSpawn(_ pane: TabPane) {
        ClaudeStateStore.shared.registerPendingSpawn(paneToken: ObjectIdentifier(pane.terminal))
    }

    /// Direct-bind (Lot 3, Task 6): a private pane's session id is known the
    /// instant it's minted (`FilteredClaudeTab.sessionId`) — no need to wait
    /// on a SessionStart hook. Called right after `pane.start()` at every
    /// private-pane spawn site. No-ops for the shared pane (`pane.wrapper ==
    /// nil`) — that one's id comes from `ClaudeBackend` itself, bound via
    /// `sharedBackendDidSpawn` below instead, since the container doesn't
    /// own that spawn. `recordPendingSpawn` is still called too at every
    /// site (belt and braces) — see `ClaudeStateStore`'s doc comment on why
    /// a redundant pending entry for an already-bound pane is harmless.
    private func bindKnownSession(_ pane: TabPane) {
        guard let wrapper = pane.wrapper else { return }
        ClaudeStateStore.shared.bindSession(paneToken: ObjectIdentifier(pane.terminal), sessionId: wrapper.sessionId)
    }

    /// The sessionId bound to `pane` — direct-bound at spawn/restart time
    /// (`bindKnownSession`, `sharedBackendDidSpawn`, `FilteredClaudeTab.restart`)
    /// for every known-id case, or matched by the spawn-order FIFO heuristic
    /// as a fallback for the one unknown-id case (`.continueMostRecent`) —
    /// see `ClaudeStateStore.bindOldestPendingSpawn`'s doc comment. Entries
    /// for closed panes are never pruned from that store — see
    /// `ClaudeStateStore.paneSessionIds`'s doc comment (where the storage
    /// lives) for why stale entries are accepted as harmless for v1.
    private func sessionId(for pane: TabPane) -> String? {
        ClaudeStateStore.shared.sessionId(forPaneToken: ObjectIdentifier(pane.terminal))
    }

    /// One PaneActivity per tab, reflecting that tab's ACTIVE pane's bound
    /// session — an unbound pane (no direct bind yet, and the FIFO fallback
    /// hasn't matched a SessionStart to it either) reads as `.idle`, same as
    /// a session with no events at all.
    private func refreshTabBarStates() {
        tabBar.states = tabPanes.indices.map { tabIdx -> PaneActivity in
            let panes = tabPanes[tabIdx]
            let idx = tabActivePaneIndex.indices.contains(tabIdx) ? tabActivePaneIndex[tabIdx] : 0
            guard panes.indices.contains(idx) else { return .idle }
            guard let sessionId = sessionId(for: panes[idx]) else { return .idle }
            return ClaudeStateStore.shared.state(forSessionId: sessionId)
        }
        // Mirror the ACTIVE tab's state into the always-visible status
        // rail's activity dot — same refresh path as tabBar.states itself,
        // so every existing call site that keeps the tab-bar dots current
        // (paneActivityChanged, closePane, markActiveTabSeen,
        // updateTabIndicator) keeps this one current for free too.
        statusRail.activity = tabBar.states.indices.contains(activeTabIndex) ? tabBar.states[activeTabIndex] : .idle
        // Task 6 follow-up: this is the activity-only refresh path — it can
        // fire (e.g. a hook event flips .idle → .working) without the
        // context-meter timer having run at all, so the tooltip needs its
        // own recompose here too, not just from applyContextMeterResult.
        updateStatusRailTooltip()
    }

    @objc private func paneActivityChanged() {
        refreshTabBarStates()
        // v1.6 backlog Task 3: an immediate refresh on every activity change
        // (prompt submitted, tool used/done, turn ended, …) — per the brief,
        // in addition to the drawer's own 5s timer. No-ops when the drawer
        // is closed (see refreshTodoDrawer's own guard).
        refreshTodoDrawer()
    }

    /// The active tab's active pane, marked as "seen" (clears a `.done`/
    /// `.needsInput` dot back to idle) and repainted. `switchTab` has its
    /// own equivalent inline (it already resolves the target pane as part
    /// of switching); this is for paths that make the SAME tab visible
    /// again WITHOUT going through switchTab — e.g. QuickTerminalPanel.show()
    /// re-summoning the panel onto whatever tab was already active.
    func markActiveTabSeen() {
        guard tabPanes.indices.contains(activeTabIndex) else { return }
        let idx = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
        let panes = tabPanes[activeTabIndex]
        guard panes.indices.contains(idx) else { return }
        if let sessionId = sessionId(for: panes[idx]) {
            ClaudeStateStore.shared.markSeen(sessionId: sessionId)
        }
        refreshTabBarStates()
    }

    /// The tab title for whichever tab currently owns a pane bound to
    /// `sessionId`. Scans forward via `ClaudeStateStore.sessionId(forPaneToken:)`
    /// per pane rather than needing a reverse (session → pane) lookup on the
    /// store — the store only exposes pane→session lookups, since containers
    /// are the only thing that know the tab/pane structure at all. Empty
    /// string if no live pane is currently bound to this session (its tab
    /// already closed, or the heuristic hasn't matched it yet).
    private func tabTitle(forSessionId sessionId: String) -> String {
        for (tabIdx, panes) in tabPanes.enumerated() {
            if panes.contains(where: { self.sessionId(for: $0) == sessionId }) {
                return tabTitles.indices.contains(tabIdx) ? tabTitles[tabIdx] : ""
            }
        }
        return ""
    }

    @objc private func claudeEventReceived(_ note: Notification) {
        guard let event = note.userInfo?["event"] as? OpusClaudeEvent else { return }
        // Pane↔session binding itself now happens inside ClaudeStateStore's
        // own .opusClaudeEvent observer (it owns the global registry) — this
        // container only needs to react to the RESULT, for notifications.
        notifyIfNeeded(for: event)
    }

    /// Step 4 — precise per-pane notification. Raises ClaudeAttention's
    /// existing bell path (same gate + 3s debounce as the raw-BEL fallback;
    /// this deliberately does NOT build a second notification pipeline)
    /// whenever an event resolves to `.needsInput`/`.done` for a session
    /// whose pane isn't the one currently on screen, or when no Opus
    /// surface is visible at all.
    private func notifyIfNeeded(for event: OpusClaudeEvent) {
        // `.idle` as the placeholder `current` is safe here: neither
        // outcome we filter for (.needsInput / .done) depends on the prior
        // state — see nextActivity's needsAttention/turnEnded branches.
        // (Only the auth_success/unrecognized-kind branch depends on
        // `current`, and that branch is never one of the two we act on.)
        let resulting = ClaudeStateStore.nextActivity(current: .idle, event: event.kind)
        guard resulting == .needsInput || resulting == .done else { return }

        // Is THIS event's session the one bound to the currently on-screen
        // pane? Compare via the forward (pane → session) lookup rather than
        // needing a reverse one — if the active pane is unbound (nil), this
        // is automatically false, which is the right call: can't prove it's
        // the visible one, so don't suppress on that basis.
        var isVisiblePane = false
        if tabPanes.indices.contains(activeTabIndex) {
            let idx = tabActivePaneIndex.indices.contains(activeTabIndex) ? tabActivePaneIndex[activeTabIndex] : 0
            let panes = tabPanes[activeTabIndex]
            if panes.indices.contains(idx) {
                isVisiblePane = sessionId(for: panes[idx]) == event.sessionId
            }
        }

        // Skip only when this IS the on-screen pane AND Opus itself is
        // visible — everything else (background tab, or Opus backgrounded
        // entirely) falls through to bellReceived, which re-checks
        // isUserLookingAtOpus() itself before doing anything.
        guard !(isVisiblePane && ClaudeAttention.shared.isUserLookingAtOpus()) else { return }

        ClaudeAttention.shared.bellReceived(title: tabTitle(forSessionId: event.sessionId))
    }

    func handlePrivateTabTerminated(_ wrapper: FilteredClaudeTab) {
        // If other live panes exist anywhere in this container, close this
        // pane silently (so the user can keep working in the others). Only
        // when this dying pane is the last live one do we surface the
        // "Session ended" overlay with Start / Close-Opus buttons.
        for paneList in tabPanes {
            if let pane = paneList.first(where: { $0.wrapper === wrapper }) {
                if hasOtherLivePane(excluding: pane) {
                    closePane(pane)
                } else {
                    showDeadOverlay(forPane: pane, isShared: false)
                }
                return
            }
        }
    }

    // MARK: Dead-pane overlay

    /// Keyed by the pane's terminal view (object identity). Holds the overlay
    /// NSView so we can remove it again on restart.
    private var deadOverlays: [ObjectIdentifier: NSView] = [:]

    @objc fileprivate func sharedBackendDidTerminate(_ note: Notification) {
        // Find tab 0's shared pane (no FilteredClaudeTab wrapper).
        guard useSharedTab0,
              tabPanes.indices.contains(0),
              let pane = tabPanes[0].first(where: { $0.wrapper == nil }) else { return }
        // Same multi-vs-last rule as private panes: if anything else is live,
        // drop the shared tab silently (closePane normally protects tab 0, so
        // call the force variant). Only show the overlay when this WAS the
        // user's last live surface.
        if hasOtherLivePane(excluding: pane) {
            closePane(pane, force: true)
        } else {
            showDeadOverlay(forPane: pane, isShared: true)
        }
    }

    /// A deliberate respawn (restart hotkey/menu, shield toggle, overlay
    /// button) makes any visible dead-session overlay stale — dismiss it.
    /// Also the direct-bind point (Lot 3, Task 6) for tab 0's shared pane:
    /// `ClaudeBackend` posts this notification on every spawn (bootstrap AND
    /// every restart) carrying `currentSessionId` in `userInfo["sessionId"]`
    /// whenever it knows it up front (fresh mint or an exact `.resume`) —
    /// bind that id straight to this container's tab-0 pane token instead of
    /// waiting on the SessionStart-hook FIFO. `userInfo["sessionId"]` is
    /// absent exactly when `resumeMode == .continueMostRecent` (claude picks
    /// the id, not us) — in that one case, fall through to `recordPendingSpawn`'s
    /// FIFO entry as before. On a RESTART with a known id, this OVERWRITES
    /// tab 0's existing binding (same token, new id) — see
    /// `ClaudeStateStore.bindSession`'s doc comment for why that's correct:
    /// the old binding pointed at a session that no longer exists.
    @objc private func sharedBackendDidSpawn(_ note: Notification) {
        guard useSharedTab0,
              tabPanes.indices.contains(0),
              let pane = tabPanes[0].first(where: { $0.wrapper == nil }) else { return }
        hideDeadOverlay(forPane: pane)
        if let sessionId = note.userInfo?["sessionId"] as? String {
            ClaudeStateStore.shared.bindSession(paneToken: ObjectIdentifier(pane.terminal), sessionId: sessionId)
        }
    }

    /// True if any pane other than `excluded` exists in this container and
    /// isn't already showing a dead-session overlay.
    private func hasOtherLivePane(excluding excluded: TabPane) -> Bool {
        for paneList in tabPanes {
            for pane in paneList {
                if pane === excluded { continue }
                let id = ObjectIdentifier(pane.terminal)
                if deadOverlays[id] != nil { continue }   // already dead
                return true
            }
        }
        return false
    }

    private func showDeadOverlay(forPane pane: TabPane, isShared: Bool) {
        let id = ObjectIdentifier(pane.terminal)
        if deadOverlays[id] != nil { return }   // already up

        let overlay = NSView(frame: pane.terminal.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        overlay.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        // The overlay is always dark; force dark appearance so plain controls
        // (the "Close Opus" button) render light text instead of inheriting the
        // system's light-mode dark text, which is invisible on this background.
        overlay.appearance = NSAppearance(named: .darkAqua)

        let title = NSTextField(labelWithString: "Session ended")
        title.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        // Was a slightly warmer one-off cream (0.96/0.91/0.82) — unified onto
        // the single OpusTheme.cream token per the harmonization spec.
        title.textColor = OpusTheme.cream
        title.alignment = .center

        let subtitle = NSTextField(labelWithString:
            isShared
                ? "The shared Claude session exited."
                : "Claude exited in this tab."
        )
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = OpusTheme.cream(0.65)
        subtitle.alignment = .center

        let restartBtn = NSButton(
            title: "Start new session",
            target: self,
            action: isShared ? #selector(restartSharedFromOverlay(_:))
                             : #selector(restartPrivateFromOverlay(_:))
        )
        restartBtn.bezelStyle = .rounded
        restartBtn.keyEquivalent = "\r"

        let closeBtn = NSButton(
            title: "Close Opus",
            target: self,
            action: #selector(quitOpusFromOverlay)
        )
        closeBtn.bezelStyle = .rounded

        // Stack vertically — robust on any pane size (no overflow, no clipping).
        let stack = NSStackView(views: [title, subtitle, restartBtn, closeBtn])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: title)        // tighten title→subtitle
        stack.setCustomSpacing(18, after: subtitle)    // breathe before buttons
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)

        // Buttons match width for a clean stacked look.
        let btnWidth = restartBtn.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        btnWidth.priority = .defaultHigh
        let closeWidth = closeBtn.widthAnchor.constraint(equalTo: restartBtn.widthAnchor)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -16),
            btnWidth,
            closeWidth
        ])

        pane.terminal.addSubview(overlay)
        deadOverlays[id] = overlay
    }

    private func hideDeadOverlay(forPane pane: TabPane) {
        let id = ObjectIdentifier(pane.terminal)
        guard let overlay = deadOverlays[id] else { return }
        overlay.removeFromSuperview()
        deadOverlays.removeValue(forKey: id)
        // Clear the terminal's screen so old (dead) output doesn't bleed into
        // the fresh session's render. ESC c is the full reset escape.
        pane.terminal.feed(text: "\u{001B}c")
    }

    /// Walk up the view hierarchy to the TerminalView hosting this control.
    /// The dead overlay nests controls (terminal > overlay > stack > button),
    /// so a fixed superview count is fragile — climb until we hit the terminal.
    static func enclosingTerminalView(from view: NSView) -> TerminalView? {
        var current: NSView? = view.superview
        while let v = current {
            if let t = v as? TerminalView { return t }
            current = v.superview
        }
        return nil
    }

    @objc private func restartSharedFromOverlay(_ sender: NSButton) {
        ClaudeBackend.shared.startIfNeeded()
        guard tabPanes.indices.contains(0),
              let pane = tabPanes[0].first(where: { $0.wrapper == nil }) else { return }
        hideDeadOverlay(forPane: pane)
    }

    @objc private func restartPrivateFromOverlay(_ sender: NSButton) {
        guard let terminal = Self.enclosingTerminalView(from: sender) else { return }
        for paneList in tabPanes {
            if let pane = paneList.first(where: { $0.terminal === terminal }),
               let wrapper = pane.wrapper {
                hideDeadOverlay(forPane: pane)
                wrapper.restart()
                return
            }
        }
    }

    @objc private func quitOpusFromOverlay() {
        NSApp.terminate(nil)
    }

    func updatePrivateTabTitle(_ wrapper: FilteredClaudeTab) {
        for (tabIdx, paneList) in tabPanes.enumerated() {
            guard let pane = paneList.first(where: { $0.wrapper === wrapper }) else { continue }
            pane.title = wrapper.title
            let activeIdx = tabActivePaneIndex.indices.contains(tabIdx) ? tabActivePaneIndex[tabIdx] : 0
            if paneList.indices.contains(activeIdx) && paneList[activeIdx] === pane {
                tabTitles[tabIdx] = wrapper.title
                tabBar.titles = tabTitles
            }
            return
        }
    }

    private func terminalFrame() -> NSRect { terminalArea.bounds }

    private func styleTerminal(_ t: TerminalView) {
        t.autoresizingMask = [.width, .height]
        t.nativeBackgroundColor = .clear
        t.nativeForegroundColor = OpusTheme.cream
        // Explicit caret color — the default can inherit the (clear) background
        // and become invisible. Cream stays readable on blur. (Was a
        // one-off warmer cream, 0.96/0.91/0.82 — unified onto the same
        // OpusTheme.cream token used everywhere else.)
        t.caretColor = OpusTheme.cream
        t.caretTextColor = OpusTheme.caretText
        t.allowMouseReporting = false
        t.font = OpusPreferences.shared.resolvedTerminalFont()
        // Scrollback applied at pane creation; existing panes keep their depth until recreated.
        t.getTerminal().changeScrollback(OpusPreferences.shared.scrollbackLines)
    }

    // MARK: Cockpit — broadcast input to every pane of the active tab (Lot 3, Task 7)

    /// Toggle broadcast arming (Cmd+Shift+I, wired in both hosts' key
    /// handlers). Arming is a silent no-op when the active tab has fewer
    /// than 2 panes — there's nothing to broadcast TO, and a lone pane
    /// broadcasting to itself is meaningless. No beep, no toast: the border
    /// painted by `refreshBroadcastBorders` is the only indicator, by
    /// design (keyboard-only feature, no toolbar button).
    func toggleBroadcast() {
        guard tabPanes.indices.contains(activeTabIndex) else { return }
        if !broadcastArmed && tabPanes[activeTabIndex].count < 2 { return }
        broadcastArmed.toggle()
    }

    /// Paint (armed) or clear (disarmed) the 2pt icy-cyan border on every
    /// pane of the ACTIVE tab. `wantsLayer` is already `true` on every
    /// `TerminalView` — SwiftTerm's `MacTerminalView` sets it in its own
    /// `init` — so `.layer` is guaranteed non-nil here without this
    /// container forcing it; the explicit set below is defensive insurance,
    /// not a fix for anything observed.
    private func refreshBroadcastBorders() {
        guard tabPanes.indices.contains(activeTabIndex) else { return }
        let width: CGFloat = broadcastArmed ? 2 : 0
        for pane in tabPanes[activeTabIndex] {
            pane.terminal.wantsLayer = true
            pane.terminal.layer?.borderWidth = width
            pane.terminal.layer?.borderColor = Self.broadcastBorderColor
        }
    }

    /// The single broadcast interception point — called both from this
    /// container's own `send(source:data:)` below (the shared pane's
    /// `TerminalViewDelegate`, since `TabPane.makeShared` sets `terminal.
    /// terminalDelegate = container`) and from `FilteredClaudeTab.
    /// send(source:data:)` (every private pane's own delegate) for every
    /// keystroke. Returns `true` when `broadcastArmed` and `source` belongs
    /// to the ACTIVE tab — in that case `data` has already been written to
    /// every pane of that tab via `broadcast(data:)`, which includes
    /// `source`'s own PTY in its walk, so the caller must NOT also send it
    /// again (that's exactly what the `true` return tells it: skip your
    /// normal single-target send). Returns `false` when disarmed, or when
    /// `source` isn't in the active tab (a background tab's pane isn't
    /// first responder and shouldn't be producing input today, but costs
    /// nothing to guard) — the caller proceeds with its own normal send.
    func interceptForBroadcast(source: TerminalView, data: ArraySlice<UInt8>) -> Bool {
        guard broadcastArmed, isPaneInActiveTab(source) else { return false }
        broadcast(data: data)
        return true
    }

    private func isPaneInActiveTab(_ terminal: TerminalView) -> Bool {
        guard tabPanes.indices.contains(activeTabIndex) else { return false }
        return tabPanes[activeTabIndex].contains { $0.terminal === terminal }
    }

    /// Write `data` to every pane of the ACTIVE tab: private panes via
    /// their own PTY wrapper (`sendInput`), the shared pane via
    /// `ClaudeBackend` directly. NEVER `terminal.feed()` on any of them —
    /// that would forge a duplicate echo; the PTYs already echo their own
    /// input back through the normal read loop, so feeding here on top of
    /// that would double every character on screen.
    ///
    /// Thin wrapper over the per-pane overload below, for the common case
    /// (keystroke broadcast) where every pane gets the SAME bytes.
    private func broadcast(data: ArraySlice<UInt8>) {
        broadcast { _ in data }
    }

    /// Per-pane variant (FINDING (a), v1.6 backlog task-1 fix round):
    /// `bytesForPane` is invoked once per pane of the active tab so each
    /// pane can determine its OWN delivery bytes independently — e.g.
    /// `deliverAsPaste` uses this to decide bracketed-paste wrapping from
    /// THAT pane's own `bracketedPasteMode`, not the active pane's. Keystroke
    /// broadcast (`broadcast(data:)` above) is just this with a
    /// constant-returning closure, so both share the exact same
    /// `sharedSent`-guarded fan-out — no duplicated iteration/guard logic
    /// between the two.
    ///
    /// `sharedSent` caps the shared-backend write at exactly one call even
    /// if the active tab somehow held two shared panes (it never does today
    /// — `TabPane.makeShared` is only ever called once, for tab 0 — but the
    /// guard is free insurance against a future regression that lets two
    /// slip into the same tab's pane list).
    private func broadcast(bytesForPane: (TabPane) -> ArraySlice<UInt8>) {
        guard tabPanes.indices.contains(activeTabIndex) else { return }
        var sharedSent = false
        for pane in tabPanes[activeTabIndex] {
            let data = bytesForPane(pane)
            if let wrapper = pane.wrapper {
                wrapper.sendInput(bytes: data)
            } else if !sharedSent {
                ClaudeBackend.shared.send(data: data)
                sharedSent = true
            }
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if interceptForBroadcast(source: source, data: data) { return }
        ClaudeBackend.shared.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0 else { return }
        ClaudeBackend.shared.setPrimarySize(cols: UInt16(newCols), rows: UInt16(newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        for (tabIdx, paneList) in tabPanes.enumerated() {
            guard let pane = paneList.first(where: { $0.terminal === source }) else { continue }
            pane.title = title
            let activeIdx = tabActivePaneIndex.indices.contains(tabIdx) ? tabActivePaneIndex[tabIdx] : 0
            if paneList.indices.contains(activeIdx) && paneList[activeIdx] === pane {
                tabTitles[tabIdx] = title
                tabBar.titles = tabTitles
            }
            return
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        if let s = String(data: content, encoding: .utf8) {
            NSPasteboard.general.setString(s, forType: .string)
        }
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {
        // Report the RINGING pane's tab title, not necessarily the active
        // one — a background tab can bell too. Same lookup pattern as
        // setTerminalTitle just above.
        for (tabIdx, paneList) in tabPanes.enumerated() where paneList.contains(where: { $0.terminal === source }) {
            ClaudeAttention.shared.bellReceived(title: tabTitles.indices.contains(tabIdx) ? tabTitles[tabIdx] : "")
            return
        }
        ClaudeAttention.shared.bellReceived(title: tabTitles.indices.contains(activeTabIndex) ? tabTitles[activeTabIndex] : "")
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
