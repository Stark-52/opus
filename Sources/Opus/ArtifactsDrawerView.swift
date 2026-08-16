// ArtifactsDrawerView — the files, folders, images and links this session
// produced. Sibling of TodoDrawerView and the same "dumb view, smart
// container" split: it owns no timer, no disk I/O and no session lookup.
// TerminalContainerView resolves the session, reads off a background queue
// and hands the resulting [Artifact] straight to `artifacts`.
//
// Thumbnails are the one exception to "no I/O": the row asks for a
// workspace icon synchronously (so a row is never blank) and a QuickLook
// thumbnail asynchronously. QuickLook runs out of process and fails
// silently, so the icon is the DEFAULT state that a thumbnail may replace,
// never an error path taken when something goes wrong.

import AppKit
import Quartz
import QuickLookThumbnailing
import OpusArtifactsKit
import OpusSecretsKit

final class ArtifactsDrawerView: NSView {
    static let width: CGFloat = RightDockGeometry.width(for: .artifacts)
    private static let cellID = NSUserInterfaceItemIdentifier("ArtifactCell")

    /// Assigned only through `update(artifacts:hasSession:hasTranscript:)`.
    /// It used to be settable directly with a `didSet` that re-filtered, but
    /// the empty-state message now depends on two flags as well as the list,
    /// and a `didSet` guarded on `artifacts != oldValue` would silently skip
    /// the refresh in the one case that matters: the list stayed empty while
    /// the REASON it is empty changed. One entry point makes that impossible.
    private(set) var artifacts: [Artifact] = []

    /// Whether a Claude session is bound to the pane this drawer belongs to.
    private var hasBoundSession = false
    /// Whether that session has a transcript on disk yet. A pane Opus spawned
    /// and nobody typed in has a session id and no transcript.
    private var hasTranscript = false

    /// The container's single way to hand this view its state. Flags first,
    /// list second, one re-filter at the end, so the message and the rows can
    /// never describe two different moments.
    func update(artifacts newArtifacts: [Artifact], hasSession: Bool, hasTranscript: Bool) {
        hasBoundSession = hasSession
        self.hasTranscript = hasTranscript
        artifacts = newArtifacts
        applyFilter()
    }

    /// What the table actually shows: `artifacts` narrowed by the filter
    /// field. Kept separate so typing in the filter never mutates the
    /// container's data.
    private var visible: [Artifact] = []
    /// What the table was last told to draw. `applyFilter` compares against
    /// this and skips `reloadData()` entirely when nothing changed, because
    /// reloading destroys the selection and with it any open preview.
    private var previouslyRendered: [Artifact] = []

    /// Whether THIS drawer currently drives the shared QuickLook panel.
    /// Tracked explicitly rather than inferred from the panel's `dataSource`,
    /// because giving ownership up that way meant nil-ing the data source,
    /// and a panel with no data source closes itself.
    private var ownsPreview = false

    private let header = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No artifacts in this session")
    private let filterField = NSTextField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

    /// Per-kind lens, composed with the text filter by AND. Lives in memory
    /// only: it is a per-moment choice, not a preference, so it resets
    /// whenever the drawer itself is rebuilt rather than persisting anywhere.
    private var kindFilter: ArtifactKindFilter = .all
    private let chipRow = NSView()
    /// Index-parallel with `ArtifactKindFilter.allCases`, built once in
    /// `buildChipRow()`. `sender.tag` is the index back into both arrays.
    private var chipButtons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        // Rounded on the left edge only, same reasoning as TodoDrawerView:
        // the right edge sits flush against the container's trailing edge.
        layer?.cornerRadius = OpusTheme.radiusControl
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.masksToBounds = true

        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = OpusTheme.cream(0.95)
        header.translatesAutoresizingMaskIntoConstraints = false

        chipRow.translatesAutoresizingMaskIntoConstraints = false
        buildChipRow()

        filterField.font = .systemFont(ofSize: 12)
        filterField.textColor = OpusTheme.cream(0.95)
        filterField.backgroundColor = OpusTheme.fieldBackground
        filterField.drawsBackground = true
        filterField.isBordered = false
        filterField.focusRingType = .none
        filterField.placeholderString = "Filter"
        filterField.target = self
        filterField.action = #selector(filterChanged)
        filterField.delegate = self
        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.wantsLayer = true
        filterField.layer?.cornerRadius = OpusTheme.radiusControl

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = OpusTheme.cream(0.45)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("artifact"))
        // Starting width only. The drawer's edge is draggable now, so the
        // column has to follow the table rather than a constant: a fixed
        // column in a resized drawer leaves a dead gutter on one side or
        // truncates every row on the other.
        column.width = Self.width - 2 * OpusTheme.controlGap
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        // Unlike TodoDrawerView, every row here IS actionable, so selection
        // has to be visible.
        tableView.selectionHighlightStyle = .regular
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelected)
        // Allow dragging a row out to an external destination (Finder, Mail,
        // Slack). Returning a pasteboard writer alone is not enough — without
        // this mask the table's default external operation is "none" and the
        // drag silently refuses to drop anywhere outside the app.
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        tableView.menu = NSMenu()
        tableView.menu?.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        addSubview(header)
        addSubview(chipRow)
        addSubview(filterField)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: OpusTheme.insetPanel),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),

            chipRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: OpusTheme.controlGap),
            chipRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            chipRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),
            chipRow.heightAnchor.constraint(equalToConstant: 20),

            filterField.topAnchor.constraint(equalTo: chipRow.bottomAnchor, constant: OpusTheme.controlGap),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),
            filterField.heightAnchor.constraint(equalToConstant: 22),

            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: OpusTheme.controlGap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OpusTheme.controlGap),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: OpusTheme.insetPanel),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -OpusTheme.insetPanel),
        ])

        header.stringValue = Self.headerText(artifacts: [])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// "Artifacts N". Pure formatter, same shape as TodoDrawerView.headerText.
    static func headerText(artifacts: [Artifact]) -> String {
        "Artifacts \(artifacts.count)"
    }

    func artifact(at row: Int) -> Artifact? {
        visible.indices.contains(row) ? visible[row] : nil
    }

    var selectedArtifact: Artifact? { artifact(at: tableView.selectedRow) }

    // MARK: Kind filter chips

    /// One borderless NSButton per `ArtifactKindFilter` case, chained
    /// left to right inside `chipRow`. `sender.tag` (set to the case's
    /// index in `allCases`) is how `chipTapped` recovers which case fired,
    /// so this array and `ArtifactKindFilter.allCases` must stay parallel.
    private func buildChipRow() {
        var previous: NSView?
        for (index, filter) in ArtifactKindFilter.allCases.enumerated() {
            let button = NSButton(title: filter.title, target: self, action: #selector(chipTapped(_:)))
            button.tag = index
            button.isBordered = false
            button.refusesFirstResponder = true
            button.font = .systemFont(ofSize: 10)
            button.translatesAutoresizingMaskIntoConstraints = false
            chipRow.addSubview(button)
            NSLayoutConstraint.activate([
                button.centerYAnchor.constraint(equalTo: chipRow.centerYAnchor),
                button.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? chipRow.leadingAnchor,
                    constant: previous == nil ? 0 : OpusTheme.controlGap)
            ])
            chipButtons.append(button)
            previous = button
        }
        // `lessThanOrEqualTo` rather than `equalTo`: this only guarantees the
        // row never overflows chipRow's bounds. It does not by itself
        // guarantee nothing clips — see the width computation in the task
        // report, which confirms the five titles fit with room to spare.
        if let last = previous {
            last.trailingAnchor.constraint(lessThanOrEqualTo: chipRow.trailingAnchor).isActive = true
        }
        restyleChips()
    }

    @objc private func chipTapped(_ sender: NSButton) {
        guard ArtifactKindFilter.allCases.indices.contains(sender.tag) else { return }
        kindFilter = ArtifactKindFilter.allCases[sender.tag]
        restyleChips()
        applyFilter()
    }

    /// One color, one meaning: cyan already means "nominal, active control"
    /// elsewhere in this theme, so the selected chip reuses it rather than
    /// inventing a second color for the same idea.
    private func restyleChips() {
        for (index, button) in chipButtons.enumerated() {
            let filter = ArtifactKindFilter.allCases[index]
            button.contentTintColor = filter == kindFilter ? OpusTheme.cyan : OpusTheme.cream(0.45)
        }
    }

    // MARK: Filter

    @objc private func filterChanged() { applyFilter() }

    private func applyFilter() {
        // Chip narrows by kind first, text filter narrows what's left. AND,
        // not OR: a chip that excludes everything stays empty no matter what
        // the text field says.
        let byKind = ArtifactKindFilter.apply(kindFilter, to: artifacts)
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visible = needle.isEmpty ? byKind : byKind.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.displayDetail.lowercased().contains(needle)
        }
        header.stringValue = Self.headerText(artifacts: artifacts)
        // Four distinct reasons the list can be empty, four distinct
        // messages. The first version of this shipped with one sentence for
        // all of them and told its owner "No artifacts in this session" for a
        // pane whose session had never been used, which is true and useless.
        // Recomputed on every call so the text always reflects the CURRENT
        // state, never whichever one was true when the view was built.
        if let reason = ArtifactsEmptyReason.resolve(
            hasSession: hasBoundSession,
            hasTranscript: hasTranscript,
            artifactCount: artifacts.count,
            visibleCount: visible.count
        ) {
            emptyLabel.stringValue = reason.message
        }
        emptyLabel.isHidden = !visible.isEmpty
        scrollView.isHidden = visible.isEmpty

        // Reload ONLY when the rows actually changed. `reloadData()` throws
        // away the selection and the first responder, and this used to run on
        // every refresh whether anything had changed or not. That is what
        // killed the QuickLook preview: the panel previews the SELECTED row,
        // the refresh wiped the selection out from under it, and the preview
        // closed on its own. The owner worked it out from the symptom, having
        // noticed the preview survived for varying lengths of time depending
        // on where in the refresh cycle it was opened.
        guard visible != previouslyRendered else { return }
        previouslyRendered = visible

        // Even a real change must not silently move the selection. Remember
        // what was selected by identity, not by index: a new artifact
        // arriving at the top shifts every index below it.
        let selectedKey = selectedArtifact?.key
        tableView.reloadData()
        if let selectedKey, let row = visible.firstIndex(where: { $0.key == selectedKey }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        // A refresh can drop the artifact an open preview is showing (the
        // session moved on, or the filter now excludes it) even when the
        // selected INDEX doesn't change, which reloadData's own
        // selection-adjustment wouldn't catch.
        reloadPreviewIfOpen()
    }

    /// Whether the keyboard is inside this drawer: the table itself, or the
    /// field editor the filter field borrows while it is being typed into
    /// (an NSTextField never becomes first responder in its own right).
    ///
    /// Final-review Important 3: the hosts used to run their Escape branch
    /// on `artifactsDrawerIsOpen` alone. With the drawer open and the
    /// TERMINAL focused, Escape closed the drawer and returned nil, so it
    /// never reached SwiftTerm and Claude could not be interrupted. Before
    /// this branch no keyCode 53 binding existed anywhere in Sources/Opus,
    /// so that was a regression on a core gesture of a daily driver. Escape
    /// now only belongs to the drawer while the drawer holds the keyboard;
    /// Cmd+Shift+A remains the close gesture from anywhere.
    var hasFocus: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === tableView { return true }
        if let editor = filterField.currentEditor(), responder === editor { return true }
        return false
    }

    /// Cmd+F, routed from the container. The field is always visible (see
    /// the finding this replaced: a hidden field with active constraints
    /// still reserves its 34pt band, so hiding it bought nothing but a
    /// state machine), so focusing is the whole job.
    /// Build the shared QuickLook panel ahead of time, without showing it.
    /// `QLPreviewPanel.shared()` is what creates it, and creating it is the
    /// slow part: doing that on the keypress made the preview feel sluggish,
    /// and doing it in the same turn as showing it was what made the first
    /// press fail outright. Called when the drawer opens, so the cost lands
    /// somewhere nobody is waiting.
    func warmPreviewPanel() {
        _ = QLPreviewPanel.shared()
    }

    func focusFilter() {
        window?.makeFirstResponder(filterField)
    }

    /// Escape, progressive: clear a non-empty filter, else hand focus back
    /// to the table, else let the caller close the drawer. Returns true when
    /// it consumed the key.
    func handleEscape() -> Bool {
        if !filterField.stringValue.isEmpty {
            filterField.stringValue = ""
            applyFilter()
            return true
        }
        if window?.firstResponder === filterField.currentEditor() {
            window?.makeFirstResponder(tableView)
            return true
        }
        return false
    }

    @objc func openSelected() {
        guard let artifact = selectedArtifact else { return }
        ArtifactActions.open(artifact)
    }

    /// Return opens the selection, which spec 8.1 lists on the same row as
    /// the double click ("Retour, double clic | Ouvre") and which the plan
    /// then dropped. Same entry point as `doubleAction`, so the two gestures
    /// cannot drift.
    ///
    /// Routed from the hosts' key monitors rather than from an
    /// `insertNewline(_:)` on this view, for the same reason Space is: the
    /// table is the first responder, and whether NSTableView forwards that
    /// command up the responder chain or consumes it to begin editing the
    /// selected row is an AppKit detail this feature should not be betting
    /// on. The monitor sees the key first, unconditionally. Guarded on the
    /// table holding focus so Return inside the filter field stays a
    /// no-op, exactly as `handleSpace` guards the space bar.
    func handleReturn() -> Bool {
        guard window?.firstResponder === tableView, selectedArtifact != nil else { return false }
        openSelected()
        return true
    }
}

extension ArtifactsDrawerView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
}

// MARK: - NSTableViewDataSource / Delegate

extension ArtifactsDrawerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    /// AppKit's own highlight is a light fill, and every label in a row is
    /// cream, so a selected row rendered as near-white on near-white and was
    /// unreadable. Same shape as ScriptsPanel's row background: a dim panel
    /// fill plus a cyan edge, cyan meaning "active" exactly as it does
    /// everywhere else in this app.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ArtifactRowBackground()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let artifact = artifact(at: row) else { return nil }
        let cell: ArtifactCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? ArtifactCellView {
            cell = reused
        } else {
            cell = ArtifactCellView()
            cell.identifier = Self.cellID
        }
        cell.configure(artifact: artifact)
        return cell
    }

    /// Drag a row out to the Finder, the Desktop, a mail composer, Slack.
    /// The real file goes, not a reference to it. This is the action that
    /// removes the original round trip entirely: no more asking Claude to
    /// copy something to the Desktop just to reach it.
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let artifact = artifact(at: row) else { return nil }
        if let path = artifact.resolvedPath { return URL(fileURLWithPath: path) as NSURL }
        if let raw = artifact.urlString, let url = URL(string: raw) { return url as NSURL }
        return nil
    }

    /// A row accepts the first mouse click even while its window isn't key
    /// (standard NSTableView behavior, the same thing that lets you click a
    /// Finder/Mail/Xcode list without activating it first) — so clicking a
    /// different row while an open preview panel floats non-key over the
    /// drawer DOES change `selectedArtifact` without any of that requiring
    /// keyboard focus. Left unhandled, the panel would keep showing the
    /// previous file while the table shows a different row selected: the
    /// drawer's whole promise is showing the right file, so this is the
    /// gesture that most needs the panel told to catch up.
    func tableViewSelectionDidChange(_ notification: Notification) {
        reloadPreviewIfOpen()
    }
}

// MARK: - Context menu

extension ArtifactsDrawerView: NSMenuDelegate, ArtifactMenuTarget {
    /// Right-click acts on the row under the cursor, which is not
    /// necessarily the selected row. Resolving it at menu-open time and
    /// selecting it keeps the two in agreement.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard let artifact = artifact(at: row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        for item in ArtifactActions.menu(for: artifact, target: self).items {
            menu.addItem(item.copy() as! NSMenuItem)
        }
        for item in menu.items { item.target = self }
    }

    func menuOpen() { if let a = selectedArtifact { ArtifactActions.open(a) } }
    func menuReveal() { if let a = selectedArtifact { ArtifactActions.revealInFinder(a) } }
    func menuRevealParent() { if let a = selectedArtifact { ArtifactActions.revealParent(a) } }
    func menuCopyPath() { if let a = selectedArtifact { ArtifactActions.copyPath(a) } }
    func menuCopyLink() { if let a = selectedArtifact { ArtifactActions.copyLink(a) } }
}

// MARK: - QuickLook

// The controller half of QuickLook. The panel finds this by walking the
// responder chain of the window that was key when it opened, which reaches
// here because `handleSpace` only fires while the table (a descendant of
// this view) is first responder.
//
// This was originally skipped, with the data source assigned directly in
// `handleSpace`. A reviewer flagged it and the objection was overruled on
// the grounds that the app has a single QuickLook call site and no second
// consumer to arbitrate with. That reasoning was about ARBITRATION and
// missed the real job of the protocol: without a controller the panel has
// no owner, drops the assignment and closes immediately.
extension ArtifactsDrawerView {
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        return true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        ownsPreview = true
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // Give up ownership WITHOUT clearing the panel's data source. Clearing
        // it leaves the panel with nothing to show, which closes it, and this
        // method is also called when the panel merely takes key status away
        // from the drawer's own window. Tearing down here is how a preview
        // could kill itself the instant it opened.
        ownsPreview = false
    }
}

extension ArtifactsDrawerView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Space previews the selected row, exactly like the Finder. Only when
    /// the TABLE has focus: with the filter field focused, space is a space.
    func handleSpace() -> Bool {
        guard window?.firstResponder === tableView,
              let artifact = selectedArtifact,
              artifact.resolvedPath != nil
        else { return false }
        guard let panel = QLPreviewPanel.shared() else { return false }
        // Only order it front. The data source and delegate are set from
        // `beginPreviewPanelControl` below, not here: the panel walks the
        // responder chain for a controller when it opens, and if it does not
        // find one it clears whatever was assigned and closes itself again.
        // Assigning directly and skipping the protocol is what made the
        // preview flash open and vanish.
        // Both halves are needed, and each was established by removing it and
        // watching what broke.
        //
        // The one-turn deferral is what makes a SINGLE press work. Ordering
        // the panel front from inside the key-handling turn does not survive;
        // one turn later, once the key-window transition has settled, it does.
        // Removing it brought the two-press behaviour straight back even with
        // the panel already built, which disproved the first explanation that
        // this was only about the panel being created too late.
        //
        // `warmPreviewPanel()`, called when the drawer opens, is what makes it
        // FAST. Building the shared panel is the expensive part, and doing it
        // on the keypress is what made the preview feel sluggish.
        DispatchQueue.main.async { panel.makeKeyAndOrderFront(nil) }
        return true
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return selectedArtifact?.resolvedPath == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let path = selectedArtifact?.resolvedPath else { return nil }
        return URL(fileURLWithPath: path) as NSURL
    }

    /// The shared panel is process-wide, but this app runs TWO independent
    /// `TerminalContainerView`s at once (main window + Quick Terminal panel),
    /// each with its own `ArtifactsDrawerView`. Ownership must be checked
    /// before acting: without this, one window's drawer closing or
    /// refreshing could reload or order out a preview that a DIFFERENT
    /// window's drawer currently owns. Whoever last pressed Space in
    /// `handleSpace()` set `panel.dataSource = self`, so `dataSource` is the
    /// ownership record — checked here, not re-decided.
    private func ownsPreviewPanel() -> Bool { ownsPreview }

    /// Re-queries the panel's data source (`numberOfPreviewItems`,
    /// `previewItemAt:`, both of which read `selectedArtifact` live) so an
    /// already-open panel catches up with whatever is selected NOW. A no-op
    /// whenever no panel has ever been created or the existing one isn't
    /// showing, so this is safe to call from every refresh and every
    /// selection change, not just the ones that happen to matter.
    func reloadPreviewIfOpen() {
        // `sharedPreviewPanelExists()` first: it's the only one of these
        // three checks that can be answered WITHOUT instantiating a panel.
        // `.isVisible` and `.dataSource` both call `QLPreviewPanel.shared()`,
        // which lazily creates the singleton on first touch — reordering
        // either ahead of the exists check would create a panel just to
        // learn that none exists.
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        guard ownsPreviewPanel() else { return }
        QLPreviewPanel.shared().reloadData()
    }

    /// Closes an open preview so it doesn't outlive the drawer it belongs
    /// to. Called from the dock's occupant-change seam (TerminalContainerView),
    /// not from `toggleArtifactsDrawer` directly, because that seam fires for
    /// every route that stops showing the artifacts drawer — the hotkey, the
    /// todo drawer taking the dock instead, anything else RightDock ever
    /// grows — while `toggleArtifactsDrawer` only covers its own call site.
    func closePreviewIfOpen() {
        // Same three-check order as reloadPreviewIfOpen, same reason: exists
        // first so a nonexistent panel is never instantiated just to be
        // inspected, then visible, then ownership last since it's the check
        // that matters only once the first two already hold.
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else { return }
        guard ownsPreviewPanel() else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }
}

/// One row: thumbnail, name, parent directory.
///
/// Spec 8 also lists a "badge de genre" on each row, and there is none.
/// That is a decision, not an oversight: the thumbnail ALREADY differs per
/// kind — a folder icon for `.folder`, a real QuickLook thumbnail for
/// `.image`, the generic link icon for `.url`, the document icon for
/// `.file` — so kind is already carried visually, in the one element of
/// the row that is always present and always 40pt tall. A badge would
/// restate it in a drawer 300pt wide whose two text lines are already
/// truncating, and the thing a reader needs from a row is WHICH file, not
/// which category. Recorded here so the gap is on the record.
private final class ArtifactCellView: NSTableCellView {
    private let thumb = NSImageView(frame: .zero)
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    /// Bumped on every configure so a thumbnail that arrives after the cell
    /// was recycled for a different artifact is dropped instead of drawn on
    /// top of the wrong row.
    private var generation = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = OpusTheme.cream(0.95)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.isSelectable = false
        nameLabel.refusesFirstResponder = true
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = OpusTheme.cream(0.45)
        // Head truncation: the tail of a path is what identifies it. A
        // middle-truncated /Users/a/…/GitHub/opus/Sources says less than
        // …/opus/Sources does.
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.maximumNumberOfLines = 1
        detailLabel.isSelectable = false
        detailLabel.refusesFirstResponder = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumb)
        addSubview(nameLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 40),
            thumb.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: OpusTheme.controlGap),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.controlGap),
            nameLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(artifact: Artifact) {
        generation += 1
        let token = generation

        nameLabel.stringValue = artifact.displayName
        // A URL harvested from a conversation can carry a token in its query
        // string. Display is redacted; ArtifactActions uses the real value.
        detailLabel.stringValue = artifact.kind == .url
            ? SecretRedactor.redactCredentialPatterns(artifact.displayDetail)
            : artifact.displayDetail

        guard let path = artifact.resolvedPath else {
            thumb.image = NSWorkspace.shared.icon(for: .url)
            return
        }
        // Synchronous icon FIRST so the row is never blank, then a real
        // thumbnail if QuickLook can produce one.
        thumb.image = NSWorkspace.shared.icon(forFile: path)
        guard artifact.kind == .image || artifact.kind == .file else { return }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path),
            size: CGSize(width: 80, height: 80),
            scale: window?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                self.thumb.image = rep.nsImage
            }
        }
    }
}

/// Selected-row background for the artifacts drawer. Mirrors
/// `ScriptRowBackground` in ScriptsPanel so the two lists highlight
/// identically, rather than one inheriting AppKit's light default and
/// rendering cream text on top of it.
private final class ArtifactRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let body = bounds.insetBy(dx: 2, dy: 0)
        OpusTheme.cream(0.09).setFill()
        NSBezierPath(roundedRect: body,
                     xRadius: OpusTheme.radiusControl, yRadius: OpusTheme.radiusControl).fill()

        let accent = NSRect(x: body.minX, y: body.minY + 3, width: 2.5, height: body.height - 6)
        OpusTheme.cyan.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: accent, xRadius: 1.25, yRadius: 1.25).fill()
    }
}
