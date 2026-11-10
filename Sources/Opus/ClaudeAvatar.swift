// ClaudeAvatar: a small spark with a face, drawn where a plain activity dot
// used to sit. Its color keeps the dot's meaning (OpusTheme.activityColor);
// its motion says the same thing a second way: the rays turn while Claude
// works, it hops and looks at you while it waits for an answer, and it
// smiles (and blushes a little) when the turn is over. Idle draws nothing
// in a tab, like the dot did. Elsewhere it sleeps when a session has ended
// and looks around an empty drawer (ClaudeAvatarView).

import AppKit

enum ClaudeAvatar {
    /// Side of the square the avatar is drawn in, in the tab strip.
    static let tabSize: CGFloat = 16
    /// Redraw rate while a state moves.
    static let framesPerSecond: Double = 24
    private static let rayCount = 8

    enum Eyes: Equatable { case open, closed, happy }

    /// Everything that moves, for one instant. Distances are fractions of
    /// the avatar's side so one pose draws at any size.
    struct Pose: Equatable {
        var rotation: CGFloat = 0
        /// Upward offset of the whole avatar.
        var hop: CGFloat = 0
        /// Horizontal glance of the eyes.
        var glance: CGFloat = 0
        /// Extra ray length, even rays get it and odd rays lose it.
        var rayPulse: CGFloat = 0
        var eyes: Eyes = .open
        /// Where the drifting "z"s are, 0 to 1; nil when awake.
        var snore: CGFloat?
        /// A drop of sweat on the brow, after a long stretch of work.
        var sweat = false
    }

    /// How long Claude works before the drop of sweat shows.
    static let sweatAfter: TimeInterval = 5 * 60

    /// Whether `activity` moves, so a host knows when to keep a timer.
    static func isAnimated(_ activity: PaneActivity, reduceMotion: Bool) -> Bool {
        !reduceMotion && (activity == .working || activity == .needsInput)
    }

    /// The pose for `activity` at `time` seconds; nil when nothing is drawn.
    /// With reduce motion every state holds its resting pose.
    static func pose(_ activity: PaneActivity, time: Double, reduceMotion: Bool = false) -> Pose? {
        let t = reduceMotion ? 0 : time
        switch activity {
        case .idle:
            return nil
        case .done:
            return Pose(eyes: .happy)
        case .working:
            return Pose(rotation: CGFloat(t * 1.8),
                        glance: CGFloat(sin(t * 2.2)) * 0.05,
                        rayPulse: CGFloat(sin(t * 6)) * 0.03,
                        eyes: blinking(t, every: 3.6) ? .closed : .open)
        case .needsInput:
            return Pose(rotation: CGFloat(sin(t * 5)) * 0.15,
                        hop: CGFloat(max(0, sin(t * 5))) * 0.12,
                        eyes: blinking(t, every: 2.8) ? .closed : .open)
        }
    }

    /// Asleep: eyes shut, rays breathing slowly, two "z"s drifting up.
    static func sleeping(time t: Double) -> Pose {
        Pose(rayPulse: CGFloat(sin(t * 1.3)) * 0.025, eyes: .closed,
             snore: CGFloat((t / 2.6).truncatingRemainder(dividingBy: 1)))
    }

    /// Awake with nothing to do: the eyes wander from side to side.
    static func lookingAround(time t: Double) -> Pose {
        Pose(glance: CGFloat(sin(t * 0.9)) * 0.06, eyes: blinking(t, every: 4.2) ? .closed : .open)
    }

    /// How long the burst of joy lasts when a turn ends.
    static let celebrationLength: Double = 1.4

    /// The burst of joy right after working turns to done: a spin and a few
    /// hops that settle into the smile. nil once it is over.
    static func celebrating(elapsed e: Double) -> Pose? {
        guard e >= 0, e < celebrationLength else { return nil }
        let k = CGFloat(1 - e / celebrationLength)
        return Pose(rotation: CGFloat(e * 7) * k,
                    hop: CGFloat(abs(sin(e * 8))) * 0.12 * k,
                    rayPulse: CGFloat(sin(e * 14)) * 0.04 * k,
                    eyes: .happy)
    }

    /// Waiting for you outranks working, which outranks done.
    static func strongest(_ states: [PaneActivity]) -> PaneActivity {
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.working) { return .working }
        if states.contains(.done) { return .done }
        return .idle
    }

    /// Eyes shut for the last 0.12 s of each period, never at rest.
    static func blinking(_ time: Double, every period: Double) -> Bool {
        guard time > 0 else { return false }
        return time.truncatingRemainder(dividingBy: period) > period - 0.12
    }

    /// Draws `pose` in `color`, centered in `rect` (its shorter side sets the size).
    /// `knockout` cuts the eyes out instead of painting them, for template images.
    static func draw(_ pose: Pose, color: NSColor, in rect: NSRect, knockout: Bool = false) {
        let s = min(rect.width, rect.height)
        let center = NSPoint(x: rect.midX, y: rect.midY + pose.hop * s)

        // Rays.
        color.setStroke()
        let rays = NSBezierPath()
        rays.lineWidth = max(1, s * 0.09)
        rays.lineCapStyle = .round
        for index in 0..<rayCount {
            let angle = pose.rotation + CGFloat(index) * .pi * 2 / CGFloat(rayCount)
            let pulse = index.isMultiple(of: 2) ? pose.rayPulse : -pose.rayPulse
            let inner = s * 0.36
            let outer = s * (0.48 + pulse)
            rays.move(to: NSPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            rays.line(to: NSPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
        }
        rays.stroke()

        // Body.
        let radius = s * 0.29
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()

        // Eyes.
        NSGraphicsContext.saveGraphicsState()
        if knockout { NSGraphicsContext.current?.compositingOperation = .destinationOut }
        OpusTheme.caretText.set()
        let eyeY = center.y + s * 0.02
        for side in [-1.0, 1.0] as [CGFloat] {
            let eyeX = center.x + side * s * 0.11 + pose.glance * s
            switch pose.eyes {
            case .open:
                let w = max(1, s * 0.075), h = max(1.6, s * 0.13)
                NSBezierPath(ovalIn: NSRect(x: eyeX - w / 2, y: eyeY - h / 2, width: w, height: h)).fill()
            case .closed:
                let line = NSBezierPath()
                line.lineWidth = max(0.8, s * 0.055)
                line.lineCapStyle = .round
                line.move(to: NSPoint(x: eyeX - s * 0.05, y: eyeY))
                line.line(to: NSPoint(x: eyeX + s * 0.05, y: eyeY))
                line.stroke()
            case .happy:
                let arc = NSBezierPath()
                arc.lineWidth = max(0.8, s * 0.055)
                arc.lineCapStyle = .round
                arc.lineJoinStyle = .round
                arc.move(to: NSPoint(x: eyeX - s * 0.055, y: eyeY - s * 0.025))
                arc.line(to: NSPoint(x: eyeX, y: eyeY + s * 0.035))
                arc.line(to: NSPoint(x: eyeX + s * 0.055, y: eyeY - s * 0.025))
                arc.stroke()
                // A little blush under each smiling eye.
                OpusTheme.red.withAlphaComponent(0.55).setFill()
                NSBezierPath(ovalIn: NSRect(x: eyeX + side * s * 0.04 - s * 0.05, y: eyeY - s * 0.12,
                                            width: s * 0.1, height: s * 0.055)).fill()
                OpusTheme.caretText.set()
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        // Sweat: a drop on the right edge of the face, point up.
        if pose.sweat {
            let x = center.x + s * 0.29, y = center.y + s * 0.04, r = s * 0.075
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: x, y: y + r * 2.4))
            drop.curve(to: NSPoint(x: x, y: y - r), controlPoint1: NSPoint(x: x + r * 1.5, y: y + r * 0.4),
                       controlPoint2: NSPoint(x: x + r * 1.4, y: y - r))
            drop.curve(to: NSPoint(x: x, y: y + r * 2.4), controlPoint1: NSPoint(x: x - r * 1.4, y: y - r),
                       controlPoint2: NSPoint(x: x - r * 1.5, y: y + r * 0.4))
            NSColor(red: 0.85, green: 0.95, blue: 1, alpha: 1).setFill()
            drop.fill()
            OpusTheme.caretText.setStroke()
            drop.lineWidth = max(0.6, s * 0.025)
            drop.stroke()
        }

        // Snoring.
        if let snore = pose.snore {
            for k in 0..<2 {
                let p = (snore + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let font = NSFont.systemFont(ofSize: s * (0.16 + 0.1 * p), weight: .bold)
                ("z" as NSString).draw(
                    at: NSPoint(x: center.x + s * (0.42 + 0.1 * p), y: center.y + s * (0.40 + 0.22 * p)),
                    withAttributes: [.font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * (1 - p))])
            }
        }
    }

    /// The avatar alone as an image, for surfaces that take one (the Dock).
    static func image(_ pose: Pose, color: NSColor, size: CGFloat, knockout: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(pose, color: color, in: rect, knockout: knockout)
            return true
        }
    }
}

/// An avatar that animates itself, for surfaces with room for one. The
/// avatar takes the lower part of the view and leaves the top for the "z"s.
final class ClaudeAvatarView: NSView {
    var color: NSColor = OpusTheme.cream(0.6) { didSet { needsDisplay = true } }
    var pose: (Double) -> ClaudeAvatar.Pose? = { ClaudeAvatar.sleeping(time: $0) } {
        didSet { needsDisplay = true }
    }
    /// Keep the top of the view for the "z"s; off, the avatar fills it, centered.
    var snoreRoom = true { didSet { needsDisplay = true } }
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self, !self.isHiddenOrHasHiddenAncestor,
                  self.window?.occlusionState.contains(.visible) == true else { return }
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard let pose = pose(still ? 0 : ProcessInfo.processInfo.systemUptime) else { return }
        let side = min(bounds.width, bounds.height) * (snoreRoom ? 0.72 : 1)
        let y = snoreRoom ? bounds.minY : bounds.midY - side / 2
        ClaudeAvatar.draw(pose, color: color, in: NSRect(x: bounds.midX - side / 2, y: y, width: side, height: side))
    }
}
