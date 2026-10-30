// ChromeStatusView: the status bar's contents: the memory the session
// carries on the left, then the context and the plan's usage on the right,
// as words and numbers (see ChromeStatus). A number turns amber, then red,
// when it needs attention; nothing else in the bar has a colour.
//
// With one bottom bar (layout B) there is no left side to spare: the memory
// joins the right-hand run instead (`showsMemory` false).

import AppKit

final class ChromeStatusView: NSView {
    var memory: String? { didSet { if memory != oldValue { refresh() } } }
    var contextFraction: CGFloat? { didSet { if contextFraction != oldValue { refresh() } } }
    var usage: [UsageWindow] = [] { didSet { if usage != oldValue { refresh() } } }
    /// True when the memory has the left side to itself (layout A).
    var showsMemory = true { didSet { if showsMemory != oldValue { refresh() } } }
    var tooltipText: String? { didSet { toolTip = tooltipText } }

    private static let font = NSFont.systemFont(ofSize: 10.5)
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)

    private let memoryLabel = NSTextField(labelWithString: "")
    private let figuresLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for label in [memoryLabel, figuresLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        figuresLabel.alignment = .right
        figuresLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        memoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            memoryLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            memoryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            figuresLabel.leadingAnchor.constraint(greaterThanOrEqualTo: memoryLabel.trailingAnchor, constant: 12),
            figuresLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            figuresLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: figuresLabel.intrinsicContentSize.height)
    }

    private func refresh() {
        memoryLabel.attributedStringValue = NSAttributedString(
            string: showsMemory ? memory ?? "" : "",
            attributes: [.font: Self.font, .foregroundColor: OpusTheme.cream(0.45)])
        figuresLabel.attributedStringValue = figures()
    }

    /// "contexte 36 %  ·  semaine 23 %  ·  5h 2 %", plus the memory in
    /// layout B. Words dim, numbers bright, the five-hour run quieter still.
    private func figures() -> NSAttributedString {
        let text = NSMutableAttributedString()
        func separator() {
            guard text.length > 0 else { return }
            text.append(NSAttributedString(string: "  ·  ", attributes: [.font: Self.font, .foregroundColor: OpusTheme.cream(0.25)]))
        }
        /// "semaine 23 %": the word, then the number in its own colour.
        func segment(_ string: String?, numberColor: NSColor, wordColor: NSColor = OpusTheme.cream(0.55)) {
            guard let string else { return }
            separator()
            let space = string.firstIndex(of: " ") ?? string.endIndex
            text.append(NSAttributedString(string: String(string[..<space]),
                                           attributes: [.font: Self.font, .foregroundColor: wordColor]))
            text.append(NSAttributedString(string: String(string[space...]),
                                           attributes: [.font: Self.numberFont, .foregroundColor: numberColor]))
        }

        let contextColor = (contextFraction ?? 0) > 0.70
            ? OpusTheme.contextColor(fraction: contextFraction ?? 0) : OpusTheme.cream(0.95)
        segment(ChromeStatus.context(fraction: contextFraction), numberColor: contextColor)
        if let week = usage.first(where: { $0.kind == .sevenDay }) {
            segment(ChromeStatus.week(usage), numberColor: Self.usageColor(week, rest: OpusTheme.cream(0.95)))
        }
        if let fiveHour = usage.first(where: { $0.kind == .fiveHour }) {
            segment(ChromeStatus.fiveHour(usage), numberColor: Self.usageColor(fiveHour, rest: OpusTheme.cream(0.35)),
                    wordColor: OpusTheme.cream(0.35))
        }
        if !showsMemory, let memory {
            separator()
            text.append(NSAttributedString(string: memory, attributes: [.font: Self.font, .foregroundColor: OpusTheme.cream(0.45)]))
        }
        return text
    }

    private static func usageColor(_ window: UsageWindow, rest: NSColor) -> NSColor {
        switch UsageLimits.level(percent: window.percent) {
        case .nominal: return rest
        case .attention: return OpusTheme.amber
        case .critical: return OpusTheme.red
        }
    }
}
