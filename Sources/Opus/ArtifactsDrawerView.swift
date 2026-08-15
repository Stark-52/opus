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
    let tableView = NSTableView(frame: .zero)
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
        filterField.isHidden = true

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
        emptyLabel.isHidden = !visible.isEmpty
        scrollView.isHidden = visible.isEmpty
        tableView.reloadData()
    }

    /// Cmd+F, routed from the container. Reveals the field and focuses it.
    func focusFilter() {
        filterField.isHidden = false
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
            filterField.isHidden = true
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

// Replaced by the real implementation in ArtifactActions.swift.
enum ArtifactActions {
    static func open(_ artifact: Artifact) {
        if let path = artifact.resolvedPath {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let s = artifact.urlString, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
