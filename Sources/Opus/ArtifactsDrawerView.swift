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

    var artifacts: [Artifact] = [] {
        didSet {
            guard artifacts != oldValue else { return }
            applyFilter()
        }
    }

    /// What the table actually shows: `artifacts` narrowed by the filter
    /// field. Kept separate so typing in the filter never mutates the
    /// container's data.
    private var visible: [Artifact] = []

    private let header = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No artifacts in this session")
    private let filterField = NSTextField(frame: .zero)
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)

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
        column.width = Self.width - 2 * OpusTheme.controlGap
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
        addSubview(filterField)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: OpusTheme.insetPanel),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),

            filterField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: OpusTheme.controlGap),
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

    // MARK: Filter

    @objc private func filterChanged() { applyFilter() }

    private func applyFilter() {
        let needle = filterField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        visible = needle.isEmpty ? artifacts : artifacts.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.displayDetail.lowercased().contains(needle)
        }
        header.stringValue = Self.headerText(artifacts: artifacts)
        // Two distinct reasons the list can be empty, two distinct messages:
        // a session with no artifacts at all versus a filter that matched
        // none of the ones that exist. Recomputed on every call so the text
        // always reflects the CURRENT artifacts/filter pair, not whichever
        // one was true when the view was built.
        emptyLabel.stringValue = artifacts.isEmpty ? "No artifacts in this session" : "No match"
        emptyLabel.isHidden = !visible.isEmpty
        scrollView.isHidden = visible.isEmpty
        tableView.reloadData()
        // A refresh can drop the artifact an open preview is showing (the
        // session moved on, or the filter now excludes it) even when the
        // selected INDEX doesn't change, which reloadData's own
        // selection-adjustment wouldn't catch. Called unconditionally here
        // rather than relying on that, so the panel is always re-queried
        // against whatever `selectedArtifact` is now.
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
}

extension ArtifactsDrawerView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { applyFilter() }
}

// MARK: - NSTableViewDataSource / Delegate

extension ArtifactsDrawerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

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

extension ArtifactsDrawerView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// Space previews the selected row, exactly like the Finder. Only when
    /// the TABLE has focus: with the filter field focused, space is a space.
    func handleSpace() -> Bool {
        guard window?.firstResponder === tableView,
              let artifact = selectedArtifact,
              artifact.resolvedPath != nil
        else { return false }
        guard let panel = QLPreviewPanel.shared() else { return false }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedArtifact?.resolvedPath == nil ? 0 : 1
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
    private func ownsPreviewPanel() -> Bool {
        QLPreviewPanel.shared().dataSource as AnyObject? === self
    }

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
