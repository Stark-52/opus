// StatusRailView — the status rail Task 2 adds per the visual-harmonization
// spec (docs/superpowers/specs/2026-08-12-opus-visual-harmonization-design.md,
// section 1 "Rail de statut"). Replaces the old top-right "ctx NN%" label +
// PaneActivityDot + ContextMeterBar trio (all still live in
// TerminalContainerView.swift/ContextMeter.swift until Task 3 wires this view
// in and removes them — NOT this task's job, see task-2-brief.md).
//
// Layout, left to right, all geometry from OpusTheme (Task 1):
//   [context rail — fills all width left of the trailing cluster]
//   [OpusTheme.controlGap]
//   [activity dot, OpusTheme.dotSize]
//   [OpusTheme.controlGap]
//   [readout label, right-aligned at the trailing edge]
//
// The rail is vertically centered on the label's baseline row. Intrinsic
// height is the label's own height (~14pt for a 10pt system font) — the rail
// and dot are small enough to always fit centered within that, so nothing
// else drives the view's height. See task-2-report.md for the exact
// arithmetic Task 3 should anchor its constraints to.
//
// No animation anywhere (the owner's explicit "retenue sur les animations UI"
// rule, restated in the design spec's "Ce qui ne change pas") — every
// setter below just flips needsDisplay / updates the label synchronously.

import AppKit

final class StatusRailView: NSView {
    /// Context-window usage, 0...1. `nil` means "no data yet" — rail and
    /// label both drop to alpha 0 (design spec: "Sans données"). The dot is
    /// unaffected — it follows `activity` on its own, independent lifecycle
    /// (e.g. Claude can be `.working` before the first transcript read has
    /// produced a usage fraction).
    var fraction: CGFloat? {
        didSet {
            updateVisibility()
            // Recompute here too (not just from `readout`'s didSet below) so
            // the label color is correct regardless of which property the
            // caller assigns first — a container setting fraction/readout/
            // tooltipText together (e.g. Task 3's applyContextMeterResult)
            // shouldn't have to assign in a specific order to avoid a
            // one-property-stale color on the very next paint.
            updateLabelColor()
            needsDisplay = true
        }
    }

    /// Drives the activity dot's color via OpusTheme.activityColor. `.idle`
    /// maps to `nil` there, which hides the dot outright.
    var activity: PaneActivity = .idle {
        didSet { needsDisplay = true }
    }

    /// The formatted "NN% · NNk" text. `nil` or empty clears the label
    /// without otherwise touching visibility (that's `fraction`'s job, since
    /// a container could theoretically set one before the other).
    var readout: String? {
        didSet {
            label.stringValue = readout ?? ""
            updateLabelColor()
        }
    }

    /// Tooltip for the whole view (rail + dot + label read as one status
    /// strip) — e.g. "353k / 1M tokens (35%)". Left for the container to
    /// compute and assign; this view does no token/limit math of its own
    /// beyond `readoutText`.
    var tooltipText: String? {
        didSet { toolTip = tooltipText }
    }

    private let label: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        l.textColor = OpusTheme.cream(0.55)
        l.alignment = .right
        return l
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        updateVisibility()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    /// Label width drives intrinsic height (~14pt for the 10pt monospaced
    /// font); width is left to the container's constraints (Task 3 pins
    /// leading/trailing), same pattern as OpusTheme's other bars.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: label.intrinsicContentSize.height)
    }

    private func updateVisibility() {
        let alpha: CGFloat = fraction == nil ? 0 : 1
        label.alphaValue = alpha
        // The rail itself is painted in draw(_:), not a subview — its alpha
        // is applied there via the same `fraction == nil` check.
    }

    private func updateLabelColor() {
        guard let fraction else {
            label.textColor = OpusTheme.cream(0.55)
            return
        }
        label.textColor = fraction > 0.70 ? OpusTheme.contextColor(fraction: fraction) : OpusTheme.cream(0.55)
    }

    override func draw(_ dirtyRect: NSRect) {
        drawDot()
        drawRail()
    }

    /// Rail track spans from the view's leading edge to the leading edge of
    /// the trailing cluster (dot + gap + label + gap), vertically centered
    /// on the label's row. Hidden (alpha 0) when `fraction == nil`, per the
    /// design spec's "Sans données" rule.
    private func drawRail() {
        guard let fraction else { return }
        let clamped = min(max(fraction, 0), 1)

        let dotSize = OpusTheme.dotSize
        let gap = OpusTheme.controlGap
        let labelWidth = label.frame.width
        let railWidth = bounds.width - dotSize - labelWidth - 2 * gap
        guard railWidth > 0 else { return }

        let railY = bounds.midY - OpusTheme.railHeight / 2
        let trackRect = NSRect(x: 0, y: railY, width: railWidth, height: OpusTheme.railHeight)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: OpusTheme.railHeight / 2, yRadius: OpusTheme.railHeight / 2)
        OpusTheme.cream(0.08).setFill()
        trackPath.fill()

        // Minimum visible sliver so a nonzero-but-tiny fraction (e.g. 1%)
        // doesn't round away to nothing — same floor idea as the old
        // ContextMeterBar, expressed here as "at least one rail-height's
        // worth of width" rather than a hardcoded pixel count.
        let fillWidth = clamped > 0 ? max(OpusTheme.railHeight, railWidth * clamped) : 0
        guard fillWidth > 0 else { return }
        let fillRect = NSRect(x: 0, y: railY, width: fillWidth, height: OpusTheme.railHeight)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: OpusTheme.railHeight / 2, yRadius: OpusTheme.railHeight / 2)
        OpusTheme.contextColor(fraction: clamped).setFill()
        fillPath.fill()
    }

    /// Dot sits immediately left of the label, same row. Hidden entirely
    /// (not just alpha 0) when OpusTheme.activityColor returns nil (`.idle`).
    private func drawDot() {
        guard let color = OpusTheme.activityColor(activity) else { return }
        let dotSize = OpusTheme.dotSize
        let gap = OpusTheme.controlGap
        let labelWidth = label.frame.width
        let dotX = bounds.width - labelWidth - gap - dotSize
        let dotY = bounds.midY - dotSize / 2
        let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    // MARK: Formatting

    /// Pure formatter: "NN% · NNk". `limit <= 0` guards against a
    /// divide-by-zero by short-circuiting to "0% · 0k" — see
    /// task-2-brief.md's Step 1 tests for the exact rounding contract
    /// (percent clamped 0...100, tokens rounded to the nearest thousand).
    static func readoutText(tokens: Int, limit: Int) -> String {
        guard limit > 0 else { return "0% · 0k" }
        let rawPercent = Int((Double(tokens) / Double(limit) * 100).rounded())
        let percent = min(max(rawPercent, 0), 100)
        let kTokens = Int((Double(tokens) / 1000).rounded())
        return "\(percent)% · \(kTokens)k"
    }
}
