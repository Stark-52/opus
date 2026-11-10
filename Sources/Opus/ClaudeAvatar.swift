// ClaudeAvatar: a small spark with a face, drawn where a plain activity dot
// used to sit. Its color keeps the dot's meaning (OpusTheme.activityColor);
// its motion says the same thing a second way: the rays turn while Claude
// works, it hops and looks at you while it waits for an answer, and it
// smiles when the turn is over. Idle draws nothing, like the dot did.

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
    }

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

    /// Eyes shut for the last 0.12 s of each period, never at rest.
    static func blinking(_ time: Double, every period: Double) -> Bool {
        guard time > 0 else { return false }
        return time.truncatingRemainder(dividingBy: period) > period - 0.12
    }

    /// Draws `pose` in `color`, centered in `rect` (its shorter side sets the size).
    static func draw(_ pose: Pose, color: NSColor, in rect: NSRect) {
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
            }
        }
    }

    /// The avatar alone as an image, for surfaces that take one (the Dock).
    static func image(_ pose: Pose, color: NSColor, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(pose, color: color, in: rect)
            return true
        }
    }
}
