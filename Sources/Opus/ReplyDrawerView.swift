// ReplyDrawerView — Cmd+Shift+C slide-in panel: Claude's latest answer,
// formatted, with a copy button on every block.
//
// The terminal hard-wraps a reply at its width and indents it, so text
// selected there pastes with line breaks and spaces in the wrong places.
// This drawer reads the answer off the transcript instead (ReplyReader),
// cuts it into blocks (ReplyMarkdown) and draws each one formatted, with a
// copy button that shows on hover: a paragraph or a list copies as plain
// text, a code block as its code, a heading as its whole section. "Tout
// copier" takes the whole answer. Text stays selectable for the odd phrase.
//
// A dumb view like the other drawers: the container finds the active
// session, reads off the main queue and hands the text to `reply`.

import AppKit
import OpusArtifactsKit

final class ReplyDrawerView: NSView {
    static let width: CGFloat = DrawerGeometry.width(for: .reply)

    /// Where the copy buttons write. Tests swap in a pasteboard of their own.
    static var pasteboard: NSPasteboard = .general

    /// The answer as Claude wrote it, or nil when the session has none yet.
    /// The same text again (every refresh tick while nothing changes) keeps
    /// the drawer as it is: scroll position, hover and the "copied" tick.
    var reply: String? {
        didSet {
            guard reply != oldValue else { return }
            blocks = reply.map(ReplyMarkdown.blocks) ?? []
            rebuild()
        }
    }

    private var blocks: [ReplyBlock] = []

    private let header = NSTextField(labelWithString: "Réponse")
    private let copyAllButton = CopyButton(title: "Tout copier")
    private let emptyLabel = NSTextField(labelWithString: "Pas encore de réponse dans cette session")
    private let scrollView = NSScrollView(frame: .zero)
    private let documentView = FlippedView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = OpusTheme.panelBackground.cgColor
        // Rounded on the edge facing the terminal only, like the other
        // drawers: the right edge sits flush against the container's.
        layer?.cornerRadius = OpusTheme.radiusControl
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        layer?.masksToBounds = true

        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.textColor = OpusTheme.cream(0.95)
        header.translatesAutoresizingMaskIntoConstraints = false

        copyAllButton.translatesAutoresizingMaskIntoConstraints = false
        copyAllButton.toolTip = "Copier toute la réponse, en texte simple"
        copyAllButton.onCopy = { [weak self] in
            guard let self else { return nil }
            return ReplyMarkdown.plainText(self.blocks)
        }

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = OpusTheme.cream(0.45)
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: OpusTheme.insetPanel, bottom: OpusTheme.insetPanel,
                                        right: OpusTheme.insetPanel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        addSubview(header)
        addSubview(copyAllButton)
        addSubview(scrollView)
        addSubview(emptyLabel)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: OpusTheme.insetPanel),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OpusTheme.insetPanel),

            copyAllButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            copyAllButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OpusTheme.insetPanel),
            copyAllButton.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: OpusTheme.controlGap),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: OpusTheme.controlGap),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -OpusTheme.controlGap),

            documentView.topAnchor.constraint(equalTo: clip.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            documentView.widthAnchor.constraint(equalTo: clip.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: OpusTheme.insetPanel),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -OpusTheme.insetPanel),
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let isEmpty = blocks.isEmpty
        emptyLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
        copyAllButton.isHidden = isEmpty

        for (index, block) in blocks.enumerated() {
            let row = BlockRow(block: block) { [weak self] in
                guard let self else { return nil }
                return ReplyMarkdown.sectionText(startingAt: index, in: self.blocks)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                       constant: -2 * OpusTheme.insetPanel).isActive = true
            if case .heading = block.kind, index > 0, let previous = stack.arrangedSubviews.dropLast().last {
                stack.setCustomSpacing(18, after: previous)
            }
        }
        // A new answer starts at its top, not wherever the last one was left.
        documentView.scroll(.zero)
    }
}

// MARK: - One block and its copy button

private final class BlockRow: NSView {
    private let block: ReplyBlock
    private let content: NSView
    private let label: NSTextField
    private let copyButton = CopyButton(title: nil)
    private var tracking: NSTrackingArea?

    init(block: ReplyBlock, copyText: @escaping () -> String?) {
        self.block = block
        label = NSTextField(labelWithAttributedString: ReplyRendering.text(for: block))
        label.isSelectable = true
        label.allowsEditingTextAttributes = true
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        content = ReplyRendering.container(for: block, around: label)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.onCopy = copyText
        copyButton.toolTip = Self.tooltip(for: block.kind)
        copyButton.alphaValue = 0
        copyButton.isHidden = block.kind == .rule

        addSubview(content)
        addSubview(copyButton)
        let gutter: CGFloat = 22
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -gutter),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private static func tooltip(for kind: ReplyBlock.Kind) -> String {
        switch kind {
        case .heading: return "Copier la section"
        case .code: return "Copier le code"
        case .table: return "Copier le tableau"
        default: return "Copier, en texte simple"
        }
    }

    // A wrapping label only knows its height once it knows its width.
    override func layout() {
        super.layout()
        let width = label.frame.width
        if width > 0, abs(label.preferredMaxLayoutWidth - width) > 0.5 {
            label.preferredMaxLayoutWidth = width
            needsLayout = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setButtonShown(true) }
    override func mouseExited(with event: NSEvent) { setButtonShown(false) }

    private func setButtonShown(_ shown: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            copyButton.animator().alphaValue = shown ? 1 : 0
        }
    }
}

// MARK: - Copy button

/// A borderless "copy" glyph (with an optional title) that turns into a
/// tick for a moment after copying, so a click visibly did something.
private final class CopyButton: NSButton {
    var onCopy: (() -> String?)?
    private let restingTitle: String?
    private var resetWork: DispatchWorkItem?

    init(title: String?) {
        restingTitle = title
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = title == nil ? .imageOnly : .imageLeading
        contentTintColor = OpusTheme.cream(0.6)
        font = .systemFont(ofSize: 11)
        target = self
        action = #selector(copyNow)
        show(copied: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func show(copied: Bool) {
        let symbol = copied ? "checkmark" : "doc.on.doc"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: copied ? "Copié" : "Copier")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        contentTintColor = copied ? OpusTheme.green : OpusTheme.cream(0.6)
        if let restingTitle {
            attributedTitle = NSAttributedString(string: copied ? "Copié" : restingTitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: copied ? OpusTheme.green : OpusTheme.cream(0.6),
            ])
        }
    }

    @objc private func copyNow() {
        guard let text = onCopy?(), !text.isEmpty else { return }
        ReplyDrawerView.pasteboard.clearContents()
        ReplyDrawerView.pasteboard.setString(text, forType: .string)
        show(copied: true)
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(copied: false) }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Rendering

enum ReplyRendering {
    static let body = NSFont.systemFont(ofSize: 12)
    static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    static func text(for block: ReplyBlock) -> NSAttributedString {
        switch block.kind {
        case .heading(let level):
            let size: CGFloat = level <= 2 ? 14 : 12.5
            return inline(block.items.first ?? "", font: .systemFont(ofSize: size, weight: .semibold),
                          color: OpusTheme.cream(0.95))
        case .paragraph:
            return inline(block.items.first ?? "", font: body, color: OpusTheme.cream(0.85))
        case .quote:
            return inline(block.items.first ?? "", font: body, color: OpusTheme.cream(0.65))
        case .list(let ordered):
            return list(block, ordered: ordered)
        case .code:
            return NSAttributedString(string: block.items.joined(separator: "\n"),
                                      attributes: [.font: mono, .foregroundColor: OpusTheme.cream(0.9)])
        case .table:
            // Header row brighter than the body, columns aligned in the
            // monospaced font; the copy keeps the markdown as written.
            let rows = ReplyMarkdown.alignedTable(block.items)
            let text = NSMutableAttributedString()
            for (index, row) in rows.enumerated() {
                text.append(NSAttributedString(string: row + (index < rows.count - 1 ? "\n" : ""), attributes: [
                    .font: index == 0 ? NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold) : mono,
                    .foregroundColor: OpusTheme.cream(index == 0 ? 0.95 : 0.8),
                ]))
            }
            return text
        case .rule:
            return NSAttributedString(string: "")
        }
    }

    /// Code and tables sit on a darker plate; a quote gets a bar on its
    /// left; everything else is the label alone.
    static func container(for block: ReplyBlock, around label: NSTextField) -> NSView {
        switch block.kind {
        case .code, .table:
            let plate = NSView()
            plate.wantsLayer = true
            plate.layer?.backgroundColor = OpusTheme.fieldBackground.cgColor
            plate.layer?.cornerRadius = 6
            plate.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(label)
            pin(label, in: plate, inset: 8)
            return plate
        case .quote:
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.backgroundColor = OpusTheme.cream(0.25).cgColor
            bar.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(bar)
            holder.addSubview(label)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                bar.topAnchor.constraint(equalTo: holder.topAnchor),
                bar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                bar.widthAnchor.constraint(equalToConstant: 2),
                label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                label.topAnchor.constraint(equalTo: holder.topAnchor),
                label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
            return holder
        case .rule:
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = OpusTheme.cream(0.12).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        default:
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(label)
            pin(label, in: holder, inset: 0)
            return holder
        }
    }

    private static func pin(_ view: NSView, in parent: NSView, inset: CGFloat) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
        ])
    }

    /// One line per item, the marker hanging in its own column so wrapped
    /// lines align with the text rather than with the bullet.
    private static func list(_ block: ReplyBlock, ordered: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, (marker, item)) in zip(block.markers, block.items).enumerated() {
            let depth = CGFloat(marker.prefix { $0 == " " }.count / 2)
            let indent = depth * 14
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = indent
            style.headIndent = indent + 16
            style.tabStops = [NSTextTab(textAlignment: .left, location: indent + 16)]
            style.paragraphSpacing = 3
            let bullet = ordered ? marker.trimmingCharacters(in: .whitespaces) : "•"
            result.append(NSAttributedString(string: bullet + "\t", attributes: [
                .font: body, .foregroundColor: OpusTheme.cream(0.5), .paragraphStyle: style,
            ]))
            let text = NSMutableAttributedString(attributedString: inline(item, font: body, color: OpusTheme.cream(0.85)))
            text.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: text.length))
            result.append(text)
            if index < block.items.count - 1 { result.append(NSAttributedString(string: "\n")) }
        }
        return result
    }

    /// Inline markdown (bold, italic, code, links) as attributed text.
    static func inline(_ markdown: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: font, .foregroundColor: color])
        }

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            var runColor = color
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    runFont = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                    runColor = OpusTheme.cyan
                }
                var traits: NSFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty {
                    runFont = NSFont(descriptor: runFont.fontDescriptor.withSymbolicTraits(traits),
                                     size: runFont.pointSize) ?? runFont
                }
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: runColor]
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = OpusTheme.cyan
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
