// TodoDrawerView — Cmd+Shift+T slide-in panel (v1.6 backlog Task 3) showing
// the active pane's Claude session task list. A pure display component: it
// owns no timer, no disk I/O, no session lookup — TerminalContainerView
// resolves the active session, reads+parses off a background queue
// (TaskListReader), and hands the resulting `[ClaudeTask]` array straight to
// `tasks`. Same "dumb view, smart container" split StatusRailView already
// uses for the context meter.
//
// Right-side drawer, fixed 260pt width, anchored top/right/bottom of the
// container — see TerminalContainerView.buildSubviews' installation site
// for why its BOTTOM constraint tracks terminalAreaBottomConstraint's own
// constant (never the container's raw bottomAnchor) rather than a fixed
// value: the status rail + tab bar band at the container's true bottom
// edge grows and shrinks (0/2-tab states), and the drawer must stay clear
// of both regardless of which state is active, not just the one that was
// on screen when it was built.

import AppKit

final class TodoDrawerView: NSView {
    static let width: CGFloat = 260

    /// Tasks to display, already loaded+sorted (`TaskListReader.load`'s
    /// numeric-filename order — oldest task first, same order the task
    /// tool itself assigns ids in). An empty array covers two distinct
    /// upstream situations the container deliberately collapses into the
    /// same "nothing to show" rendering: a session that genuinely has zero
    /// tasks, AND "no bound session at all" (see
    /// TerminalContainerView.refreshTodoDrawer's doc comment — showing the
    /// empty state beats guessing at some OTHER session's tasks).
    var tasks: [ClaudeTask] = [] {
        didSet {
            header.stringValue = Self.headerText(tasks: tasks)
            let isEmpty = tasks.isEmpty
            emptyLabel.isHidden = !isEmpty
            scrollView.isHidden = isEmpty
            tableView.reloadData()
        }
    }

    private let header = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No tasks in this session")
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private static let cellID = NSUserInterfaceItemIdentifier("TodoTaskCell")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        // Rounded on the LEFT edge only (the edge facing into the terminal
        // area) — the right edge sits flush against the container's own
        // trailing edge, so rounding it would just clip a corner against a
        // straight edge for no visual benefit. This view is never flipped
        // (no isFlipped override, matching every other plain container in
        // this file's neighbors — TerminalContainerView itself included),
        // so layer-space minY is the BOTTOM: minXMinY = bottom-left,
        // minXMaxY = top-left.
        layer?.cornerRadius = OpusTheme.radiusControl
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.masksToBounds = true

        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = OpusTheme.cream(0.95)
        header.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = OpusTheme.cream(0.45)
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        column.width = Self.width - 2 * OpusTheme.controlGap
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowSizeStyle = .custom
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        // Read-only list — nothing to click, no row-level action, so no
        // selection highlight to draw (unlike SessionSwitcherPanel/
        // PromptPalettePanel, which both navigate to the selected row).
        tableView.selectionHighlightStyle = .none
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        addSubview(header)
        addSubview(scrollView)
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: OpusTheme.insetPanel),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: OpusTheme.controlGap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OpusTheme.controlGap),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: OpusTheme.insetPanel),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -OpusTheme.insetPanel),
        ])

        header.stringValue = Self.headerText(tasks: [])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// "Tasks N / M" — N completed, M total. Pure formatter, same shape as
    /// StatusRailView.readoutText: no I/O, easy to eyeball-verify against
    /// the brief's literal example ("Tasks 7 / 23").
    static func headerText(tasks: [ClaudeTask]) -> String {
        let completed = tasks.filter { $0.status == .completed }.count
        return "Tasks \(completed) / \(tasks.count)"
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension TodoDrawerView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { tasks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tasks.indices.contains(row) else { return nil }
        let cell: TodoTaskCellView
        if let reused = tableView.makeView(withIdentifier: Self.cellID, owner: self) as? TodoTaskCellView {
            cell = reused
        } else {
            cell = TodoTaskCellView()
            cell.identifier = Self.cellID
        }
        cell.configure(task: tasks[row])
        return cell
    }

    /// Plain, unselectable row background — this list has no click/selection
    /// affordance at all (see `selectionHighlightStyle = .none` above), so
    /// the default NSTableRowView would otherwise still draw AppKit's own
    /// alternating-row/selection chrome underneath the cell; a bare row view
    /// with no custom drawing keeps the drawer's own `panelBackground` as
    /// the only thing visible behind each row, same clear-background intent
    /// `tableView.backgroundColor = .clear` above already states for the
    /// table as a whole.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        NSTableRowView()
    }
}

/// One row: a status glyph, then the task's subject on a single truncating
/// line. Colors are entirely a function of `task.status` — see the brief's
/// literal color table, reproduced in `configure` below.
private final class TodoTaskCellView: NSTableCellView {
    private let glyphLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        glyphLabel.font = .systemFont(ofSize: 11)
        glyphLabel.alignment = .center
        glyphLabel.isSelectable = false
        glyphLabel.refusesFirstResponder = true
        glyphLabel.translatesAutoresizingMaskIntoConstraints = false

        subjectLabel.font = .systemFont(ofSize: 12)
        // Single line, tail-truncating — a long subject ("Lot A: encodeur
        // WebP réel (libwebp SPM)…") must never wrap and push later rows
        // out of their fixed 20pt row height.
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.maximumNumberOfLines = 1
        subjectLabel.isSelectable = false
        subjectLabel.refusesFirstResponder = true
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(glyphLabel)
        addSubview(subjectLabel)
        NSLayoutConstraint.activate([
            glyphLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.controlGap),
            glyphLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyphLabel.widthAnchor.constraint(equalToConstant: 14),

            subjectLabel.leadingAnchor.constraint(equalTo: glyphLabel.trailingAnchor, constant: OpusTheme.controlGap),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.controlGap),
            subjectLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(task: ClaudeTask) {
        subjectLabel.stringValue = task.subject
        switch task.status {
        case .completed:
            glyphLabel.stringValue = "●"
            glyphLabel.textColor = OpusTheme.green
            subjectLabel.textColor = OpusTheme.cream(0.35)
        case .inProgress:
            glyphLabel.stringValue = "◐"
            glyphLabel.textColor = OpusTheme.cyan
            subjectLabel.textColor = OpusTheme.cream(0.95)
        case .pending:
            glyphLabel.stringValue = "○"
            glyphLabel.textColor = OpusTheme.cream(0.35)
            subjectLabel.textColor = OpusTheme.cream(0.55)
        }
    }
}
