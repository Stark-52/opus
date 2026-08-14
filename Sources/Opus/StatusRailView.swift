// StatusRailView — the status rail Task 2 adds per the visual-harmonization
// spec (docs/superpowers/specs/2026-08-12-opus-visual-harmonization-design.md,
// section 1 "Rail de statut"). Replaced the old top-right "ctx NN%" label +
// PaneActivityDot + ContextMeterBar trio — Task 3 wired this view into
// TerminalContainerView and deleted all three (PaneActivityDot and
// ContextMeterBar no longer exist anywhere in the codebase).
//
// Layout, left to right, all geometry from OpusTheme (Task 1):
//   [context rail — fills all width left of the trailing cluster]
//   [OpusTheme.controlGap]
//   [activity dot, OpusTheme.dotSize]
//   [OpusTheme.controlGap]
//   [readout label — fixed labelColumnWidth (72pt), text right-aligned
//    within it, column pinned to the trailing edge — see labelColumnWidth's
//    doc comment below (Fix round 1) for why this is fixed rather than
//    intrinsic: an intrinsic-width label made the dot and the rail's right
//    edge visibly shift every time the readout's digit count changed]
//
// The rail is vertically centered on the label's baseline row. Intrinsic
// height is the label's own height (measured 13pt for the 10pt monospaced-
// digit font) — the rail and dot are small enough to always fit centered
// within that, so nothing else drives the view's height. See
// task-2-report.md and task-3-report.md for the exact arithmetic
// TerminalContainerView's constraints anchor to.
//
// The fill EASES to a new value (see animateFill) and the readout fades in
// and out; the dot and the text itself change synchronously, because a
// number sliding through values it never held would be a lie told for
// decoration.
//
// This view used to forbid animation outright, on the authority of a
// project-wide "no UI animation" rule. That rule was never this project's:
// it came from an unrelated web codebase and was applied here by mistake,
// then quoted in a design spec, then enforced here. Nothing about a status
// rail requires it to be motionless.
//
// The one constraint that IS real, and that the animation is built around:
// the rail must never lie about the state it shows. Hence displayedFraction
// lands exactly on the target rather than near it, and the colour is
// computed from the same eased value as the width, so the fill can never
// show a length from one moment and a hue from another.

import AppKit

final class StatusRailView: NSView {
    /// Context-window usage, 0...1. `nil` means "no data yet" — rail and
    /// label both drop to alpha 0 (design spec: "Sans données"). The dot is
    /// unaffected — it follows `activity` on its own, independent lifecycle
    /// (e.g. Claude can be `.working` before the first transcript read has
    /// produced a usage fraction).
    var fraction: CGFloat? {
        didSet {
            animateFill(to: fraction)
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

    /// Fixed column width for the readout label (Fix round 1). Measured
    /// worst case at 10pt monospaced digits is "100% · 1000k" ≈ 68.8pt vs.
    /// "5% · 7k" ≈ 36.7pt — a ~32pt swing that, left to intrinsic sizing,
    /// shifted `label.frame.width` (and therefore both `dotX` in `drawDot()`
    /// and `railWidth` in `drawRail()`, which read it directly) on nearly
    /// every repaint as the boundaries in `readoutText` (9→10%, 99→100%,
    /// 9k→10k, 99k→100k, 999k→1000k) are crossed — visible jitter in the
    /// dot and the rail's right edge. 72pt covers the 68.8pt worst case
    /// with headroom and lands on the 6pt (OpusTheme.controlGap) grid. The
    /// label stays right-aligned (`l.alignment = .right` above) inside this
    /// fixed column so short readouts still hug the trailing edge instead
    /// of floating in the middle of it.
    static let labelColumnWidth: CGFloat = 72

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth)
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
        guard label.alphaValue != alpha else { return }
        // Faded rather than snapped: the readout appearing is the rail coming
        // alive, and a hard cut there reads as a glitch next to a fill that
        // eases. Short enough that nothing waits on it.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = alpha
        }
        // The rail itself is painted in draw(_:), not a subview — its alpha
        // is applied there via the same `fraction == nil` check.
    }

    // MARK: Fill animation

    /// What the rail is CURRENTLY drawing, which lags `fraction` while a
    /// change eases in. `fraction` remains the truth; this is only ever a
    /// transient view of it, and `finish` below guarantees it lands exactly
    /// on the real value rather than near it.
    private var displayedFraction: CGFloat = 0
    private var fillAnimation: (from: CGFloat, to: CGFloat, start: Date)?
    private var fillTimer: Timer?

    private static let fillDuration: TimeInterval = 0.28

    /// Eases the drawn fill toward a new value.
    ///
    /// Starting from `displayedFraction` rather than from the previous target
    /// matters: a second change arriving mid-animation continues from where
    /// the bar actually is, instead of snapping back to where the last
    /// animation began. Context usage updates every few seconds, so
    /// mid-animation changes are the normal case, not the edge case.
    private func animateFill(to target: CGFloat?) {
        fillTimer?.invalidate()
        fillTimer = nil

        guard let target else {
            // No data: nothing to ease toward. Reset so the next real value
            // grows from empty rather than from a stale position.
            fillAnimation = nil
            displayedFraction = 0
            return
        }

        let clamped = min(max(target, 0), 1)
        guard abs(clamped - displayedFraction) > 0.0005 else {
            displayedFraction = clamped
            return
        }

        fillAnimation = (from: displayedFraction, to: clamped, start: Date())
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.stepFill()
        }
        // .common, not the default mode: a timer in the default mode stops
        // firing while a menu is open or a window is being resized, which
        // would freeze the bar mid-animation and leave it showing a value
        // that was never true.
        RunLoop.main.add(timer, forMode: .common)
        fillTimer = timer
    }

    private func stepFill() {
        guard let animation = fillAnimation else {
            fillTimer?.invalidate()
            fillTimer = nil
            return
        }
        let elapsed = Date().timeIntervalSince(animation.start)
        let progress = min(max(elapsed / Self.fillDuration, 0), 1)
        // easeOutCubic: quick off the mark, settling gently. Matches the
        // panels' own easeOut curves so the app moves one way, not three.
        let eased = 1 - pow(1 - progress, 3)
        displayedFraction = animation.from + (animation.to - animation.from) * CGFloat(eased)

        if progress >= 1 {
            // Land on the exact target. Interpolation alone would leave a
            // float epsilon behind, and the whole justification for animating
            // this at all is that it still ends up telling the truth.
            displayedFraction = animation.to
            fillAnimation = nil
            fillTimer?.invalidate()
            fillTimer = nil
        }
        needsDisplay = true
    }

    /// A view removed from its window must not keep a run-loop timer alive.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        fillTimer?.invalidate()
        fillTimer = nil
        fillAnimation = nil
    }

    deinit {
        fillTimer?.invalidate()
    }

    private func updateLabelColor() {
        guard let fraction else {
            label.textColor = OpusTheme.cream(0.55)
            return
        }
        // Clamp before both the threshold check and the color lookup (same
        // clamp `drawRail()` applies) so the label and the rail fill can
        // never disagree about which side of 0.70 an out-of-range fraction
        // (e.g. a pre-safety-auto-bump overrun) falls on.
        let clamped = min(max(fraction, 0), 1)
        label.textColor = clamped > 0.70 ? OpusTheme.contextColor(fraction: clamped) : OpusTheme.cream(0.55)
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
        // Presence still keys off `fraction` (no data means no rail), but the
        // WIDTH comes from displayedFraction so a change eases in. The colour
        // follows the same eased value, so the fill never shows a length and
        // a hue from two different moments.
        guard fraction != nil else { return }
        let clamped = min(max(displayedFraction, 0), 1)

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
        // worth of width" rather than a hardcoded pixel count. DELIBERATE —
        // not in the original brief, added because a 1% fill rounding down
        // to 0pt-wide is a real regression (the whole point of the rail is
        // that the rail is findable without being told where it is). Do not
        // simplify this back to `railWidth * clamped` alone.
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
        // Clamped at 0 same as percent above — a negative token count
        // shouldn't ever happen in practice (ContextMeter sums non-negative
        // usage fields), but the formatter is a pure function callers can
        // hand anything to, and "-1k" reads as a bug, not a token count.
        let kTokens = max(Int((Double(tokens) / 1000).rounded()), 0)
        return "\(percent)% · \(kTokens)k"
    }
}
