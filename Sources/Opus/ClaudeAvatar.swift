// ClaudeAvatar: a small spark with a face, drawn where a plain activity dot
// used to sit. Its color keeps the dot's meaning (OpusTheme.activityColor);
// its motion says the same thing a second way: the rays turn while Claude
// works, it hops and looks at you while it waits for an answer, and it
// smiles (and blushes a little) when the turn is over. Idle draws nothing
// in a tab, like the dot did. Elsewhere it sleeps when a session has ended
// and looks around an empty drawer (ClaudeAvatarView).

import AppKit

extension Notification.Name {
    /// Opus > Animate Claude was switched; hosts restart or stop their frames.
    static let opusAvatarMotionChanged = Notification.Name("com.stark52.opus.avatarMotionChanged")
}

enum ClaudeAvatar {
    /// Side of the square the avatar is drawn in, in the tab strip.
    static let tabSize: CGFloat = 16
    /// Redraw rate while a state moves.
    static let framesPerSecond: Double = 24
    private static let rayCount = 8

    enum Eyes: Equatable { case open, closed, happy, tired }
    enum Hat: Equatable { case nightcap, santa, party }

    /// The hat the calendar puts on: Santa's from December 15th to the 31st,
    /// a nightcap on a sleeper from 22 h to 7 h, else none.
    static func seasonalHat(_ date: Date, asleep: Bool, calendar: Calendar = .current) -> Hat? {
        let parts = calendar.dateComponents([.month, .day, .hour], from: date)
        if parts.month == 12, (parts.day ?? 0) >= 15 { return .santa }
        if asleep, let hour = parts.hour, hour >= 22 || hour < 7 { return .nightcap }
        return nil
    }

    /// Week usage, in percent, from which open eyes droop.
    static let tiredAt: Double = 90

    /// `pose` with heavy lids when the week is nearly spent; other eyes stay.
    /// At 100 % the week is spent: asleep, whatever it was doing.
    static func tired(_ pose: Pose, weekPercent: Double?) -> Pose {
        guard let weekPercent, weekPercent >= tiredAt else { return pose }
        if weekPercent >= 100 {
            var spent = pose
            spent.eyes = .closed
            spent.asleep = true
            spent.asks = false
            return spent
        }
        guard pose.eyes == .open else { return pose }
        var drooping = pose
        drooping.eyes = .tired
        return drooping
    }

    /// The week starts over: it was nearly spent and now it is mostly free.
    static func weekReset(from old: Double?, to new: Double?) -> Bool {
        guard let old, let new else { return false }
        return old >= tiredAt && new < 50
    }

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
        /// Upward look of the eyes, as when thinking.
        var lift: CGFloat = 0
        /// Angle added to the top right ray: a hand that waves.
        var wave: CGFloat = 0
        /// A "?" bubble beside the head, drawn only where it can be read.
        var asks = false
        /// How wide the mouth opens in a yawn, 0 to 1; no mouth at 0.
        var yawn: CGFloat = 0
        /// Squash (positive: wider and shorter, on landing) or stretch
        /// (negative: on take-off), about the bottom of the body.
        var squash: CGFloat = 0
        /// Progress of a confetti burst, 0 to 1; nil without one.
        var confetti: CGFloat?
        /// A hat it wears whatever the date; nil leaves it to the calendar.
        var hat: Hat?
        /// Asleep, which earns a nightcap late at night.
        var asleep = false
        /// A magnifying glass held out, for looking around.
        var magnifier = false
    }

    /// Smallest side at which eye highlights and confetti are drawn.
    static let detailMinSide: CGFloat = 24

    /// Smallest side at which the "?" bubble is drawn.
    static let bubbleMinSide: CGFloat = 30

    /// How long Claude works before the drop of sweat shows.
    static let sweatAfter: TimeInterval = 5 * 60

    /// Avatars may move: neither the system's reduce motion nor Opus >
    /// Animate Claude holds them still.
    static var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && OpusPreferences.shared.avatarAnimated
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
            // Every six seconds, a second and a half looking up to the right.
            let thinking = t.truncatingRemainder(dividingBy: 6) > 4.5
            return Pose(rotation: CGFloat(t * 1.8),
                        glance: thinking ? 0.05 : CGFloat(sin(t * 2.2)) * 0.05,
                        rayPulse: CGFloat(sin(t * 6)) * 0.03,
                        eyes: blinking(t, every: 3.6) ? .closed : .open,
                        lift: thinking ? 0.05 : 0)
        case .needsInput:
            // Crouch while on the ground, stretch a little leaving it.
            let s5 = sin(t * 5)
            let squash = s5 < 0 ? -s5 * 0.12 : (s5 > 0 ? -abs(cos(t * 5)) * 0.05 : 0)
            return Pose(rotation: CGFloat(s5) * 0.15,
                        hop: CGFloat(max(0, s5)) * 0.12,
                        eyes: blinking(t, every: 2.8) ? .closed : .open,
                        wave: CGFloat(sin(t * 10)) * 0.45,
                        asks: true,
                        squash: CGFloat(squash))
        }
    }

    /// Asleep: eyes shut, rays breathing slowly, two "z"s drifting up.
    /// Every nine seconds the last 1.5 s are a yawn.
    static func sleeping(time t: Double) -> Pose {
        let phase = t.truncatingRemainder(dividingBy: 9)
        return Pose(rayPulse: CGFloat(sin(t * 1.3)) * 0.025, eyes: .closed,
                    snore: CGFloat((t / 2.6).truncatingRemainder(dividingBy: 1)),
                    yawn: phase > 7.5 ? CGFloat(sin(.pi * (phase - 7.5) / 1.5)) : 0,
                    asleep: true)
    }

    /// Awake with nothing to do: the eyes wander from side to side.
    static func lookingAround(time t: Double) -> Pose {
        Pose(glance: CGFloat(sin(t * 0.9)) * 0.06, eyes: blinking(t, every: 4.2) ? .closed : .open, magnifier: true)
    }

    /// How long the burst of joy lasts when a turn ends.
    static let celebrationLength: Double = 1.4

    /// The burst of joy right after working turns to done: a spin and a few
    /// hops that settle into the smile. nil once it is over.
    static func celebrating(elapsed e: Double) -> Pose? {
        guard e >= 0, e < celebrationLength else { return nil }
        let k = CGFloat(1 - e / celebrationLength)
        let bounce = CGFloat(abs(sin(e * 8)))
        return Pose(rotation: CGFloat(e * 7) * k,
                    hop: bounce * 0.12 * k,
                    rayPulse: CGFloat(sin(e * 14)) * 0.04 * k,
                    eyes: .happy,
                    squash: (1 - bounce) * 0.1 * k,
                    confetti: CGFloat(e / celebrationLength),
                    hat: .party)
    }

    /// How long getting up to work lasts.
    static let gettingUpLength: Double = 0.6

    /// Getting up to work: a stretch upward with a quick yawn, eyes opening
    /// halfway through. nil once it is over.
    static func gettingUp(elapsed e: Double) -> Pose? {
        guard e >= 0, e < gettingUpLength else { return nil }
        let arc = CGFloat(sin(.pi * e / gettingUpLength))
        return Pose(eyes: e < 0.25 ? .closed : .open,
                    yawn: e < 0.4 ? CGFloat(sin(.pi * e / 0.4)) : 0,
                    squash: -0.12 * arc)
    }

    /// Waiting for you outranks working, which outranks done.
    static func strongest(_ states: [PaneActivity]) -> PaneActivity {
        if states.contains(.needsInput) { return .needsInput }
        if states.contains(.working) { return .working }
        if states.contains(.done) { return .done }
        return .idle
    }

    /// How long Claude waits before its hops speed up.
    static let insistAfter: TimeInterval = 3 * 60
    /// How much faster an insistent wait moves.
    static let insistSpeed: Double = 1.6

    /// Late at night (23 h to 6 h) an awake avatar yawns once every twelve
    /// seconds, for 1.5 s; other hours, and closed or smiling eyes, are left be.
    static func lateNight(_ pose: Pose, hour: Int, time t: Double) -> Pose {
        // Closed counts as awake here: a blink inside a yawn keeps the mouth.
        guard hour >= 23 || hour < 6, pose.eyes != .happy else { return pose }
        let phase = t.truncatingRemainder(dividingBy: 12)
        guard phase > 10.5 else { return pose }
        var yawning = pose
        yawning.yawn = CGFloat(sin(.pi * (phase - 10.5) / 1.5))
        return yawning
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

        // Confetti, behind the avatar: twelve pieces thrown out from the
        // edge of the body, falling, turning, fading.
        if let burst = pose.confetti, s >= detailMinSide, !knockout {
            let colors = [OpusTheme.cyan, OpusTheme.amber, OpusTheme.red, OpusTheme.green, OpusTheme.cream]
            let start = NSPoint(x: rect.midX, y: rect.midY)
            for k in 0..<12 {
                let angle = CGFloat(k) / 12 * .pi * 2 + 0.3
                let reach = s * (0.3 + (0.3 + 0.12 * CGFloat(k % 3)) * burst)
                let x = start.x + cos(angle) * reach
                let y = start.y + sin(angle) * reach - s * 0.35 * burst * burst
                let turn = angle + burst * 9
                let w = s * 0.085, h = s * 0.042
                let c = cos(turn), sn = sin(turn)
                let offsets: [(CGFloat, CGFloat)] = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
                var corners: [NSPoint] = []
                for (dx, dy) in offsets {
                    let px: CGFloat = x + dx * c - dy * sn
                    let py: CGFloat = y + dx * sn + dy * c
                    corners.append(NSPoint(x: px, y: py))
                }
                let piece = NSBezierPath()
                piece.move(to: corners[0])
                corners.dropFirst().forEach { piece.line(to: $0) }
                piece.close()
                colors[k % colors.count].withAlphaComponent(1 - burst * burst).setFill()
                piece.fill()
            }
        }

        // Squash and stretch about the bottom of the body.
        // Confetti, drawn before, stays outside the transform.
        NSGraphicsContext.saveGraphicsState()
        if pose.squash != 0 {
            let base = NSPoint(x: center.x, y: center.y - s * 0.3)
            let squash = NSAffineTransform()
            squash.translateX(by: base.x, yBy: base.y)
            squash.scaleX(by: 1 + pose.squash, yBy: 1 - pose.squash)
            squash.translateX(by: -base.x, yBy: -base.y)
            squash.concat()
        }

        // Rays.
        color.setStroke()
        let rays = NSBezierPath()
        rays.lineWidth = max(1, s * 0.09)
        rays.lineCapStyle = .round
        for index in 0..<rayCount {
            // Ray 1 points up and to the right: the waving hand.
            let angle = pose.rotation + CGFloat(index) * .pi * 2 / CGFloat(rayCount) + (index == 1 ? pose.wave : 0)
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

        // Hat, on the body and under the face's features.
        if let hat = pose.hat ?? seasonalHat(Date(), asleep: pose.asleep) {
            drawHat(hat, center: center, s: s, knockout: knockout)
        }

        // Eyes.
        NSGraphicsContext.saveGraphicsState()
        if knockout { NSGraphicsContext.current?.compositingOperation = .destinationOut }
        OpusTheme.caretText.set()
        let eyeY = center.y + s * (0.02 + pose.lift)
        for side in [-1.0, 1.0] as [CGFloat] {
            let eyeX = center.x + side * s * 0.11 + pose.glance * s
            switch pose.eyes {
            case .open:
                let w = max(1, s * 0.075), h = max(1.6, s * 0.13)
                NSBezierPath(ovalIn: NSRect(x: eyeX - w / 2, y: eyeY - h / 2, width: w, height: h)).fill()
                // A glint, where the eye is big enough to hold one.
                if s >= detailMinSide, !knockout {
                    let r = s * 0.02
                    OpusTheme.cream.setFill()
                    NSBezierPath(ovalIn: NSRect(x: eyeX - w * 0.2 - r, y: eyeY + h * 0.18 - r, width: r * 2, height: r * 2)).fill()
                    OpusTheme.caretText.set()
                }
            case .tired:
                // The lower half of an open eye under a flat lid.
                let w = max(1, s * 0.075), h = max(1.6, s * 0.13)
                let eye = NSRect(x: eyeX - w / 2, y: eyeY - h / 2, width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                NSRect(x: eye.minX - 1, y: eye.minY - 1, width: eye.width + 2, height: h * 0.5 + 1).clip()
                NSBezierPath(ovalIn: eye).fill()
                NSGraphicsContext.restoreGraphicsState()
                let lid = NSBezierPath()
                lid.lineWidth = max(0.7, s * 0.04)
                lid.lineCapStyle = .round
                lid.move(to: NSPoint(x: eyeX - s * 0.055, y: eyeY + s * 0.005))
                lid.line(to: NSPoint(x: eyeX + s * 0.055, y: eyeY + s * 0.005))
                lid.stroke()
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
                // A little blush under each smiling eye; none in a template
                // image, where it would punch a hole.
                if !knockout {
                    OpusTheme.red.withAlphaComponent(0.55).setFill()
                    NSBezierPath(ovalIn: NSRect(x: eyeX + side * s * 0.04 - s * 0.05, y: eyeY - s * 0.12,
                                                width: s * 0.1, height: s * 0.055)).fill()
                    OpusTheme.caretText.set()
                }
            }
        }

        // A yawning mouth.
        if pose.yawn > 0.05 {
            let w = s * 0.09, h = s * 0.13 * pose.yawn
            NSBezierPath(ovalIn: NSRect(x: center.x - w / 2, y: center.y - s * 0.1 - h / 2, width: w, height: h)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // A "?" in a small cream bubble, up and to the right of the head.
        if pose.asks, s >= bubbleMinSide, !knockout {
            let r = s * 0.15
            let bubble = NSPoint(x: center.x + s * 0.42, y: center.y + s * 0.4)
            OpusTheme.cream.setFill()
            NSBezierPath(ovalIn: NSRect(x: bubble.x - r, y: bubble.y - r, width: r * 2, height: r * 2)).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: bubble.x - r * 0.7, y: bubble.y - r * 0.5))
            tail.line(to: NSPoint(x: bubble.x - r * 1.3, y: bubble.y - r * 1.3))
            tail.line(to: NSPoint(x: bubble.x - r * 0.2, y: bubble.y - r * 0.9))
            tail.fill()
            let font = NSFont.systemFont(ofSize: r * 1.5, weight: .heavy)
            let mark = "?" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: OpusTheme.caretText]
            let size = mark.size(withAttributes: attrs)
            mark.draw(at: NSPoint(x: bubble.x - size.width / 2, y: bubble.y - size.height / 2), withAttributes: attrs)
        }

        // A magnifying glass held out on the right, sweeping with the gaze.
        if pose.magnifier, s >= detailMinSide, !knockout {
            let lens = NSPoint(x: center.x + s * (0.36 + pose.glance * 1.5), y: center.y - s * 0.06)
            let r = s * 0.11
            let ring = NSRect(x: lens.x - r, y: lens.y - r, width: r * 2, height: r * 2)
            OpusTheme.cream(0.15).setFill()
            NSBezierPath(ovalIn: ring).fill()
            OpusTheme.cream(0.85).setStroke()
            let rim = NSBezierPath(ovalIn: ring)
            rim.lineWidth = s * 0.035
            rim.stroke()
            let handle = NSBezierPath()
            handle.lineWidth = s * 0.05
            handle.lineCapStyle = .round
            handle.move(to: NSPoint(x: lens.x + r * 0.7, y: lens.y - r * 0.7))
            handle.line(to: NSPoint(x: lens.x + r * 1.6, y: lens.y - r * 1.6))
            handle.stroke()
        }

        // Sweat: a drop on the right edge of the face, point up.
        if pose.sweat {
            let x = center.x + s * 0.29, y = center.y + s * 0.04, r = s * 0.075
            let drop = NSBezierPath()
            drop.move(to: NSPoint(x: x, y: y + r * 2.4))
            drop.curve(to: NSPoint(x: x, y: y - r), controlPoint1: NSPoint(x: x + r * 1.5, y: y + r * 0.4),
                       controlPoint2: NSPoint(x: x + r * 1.4, y: y - r))
            drop.curve(to: NSPoint(x: x, y: y + r * 2.4), controlPoint1: NSPoint(x: x - r * 1.4, y: y - r),
                       controlPoint2: NSPoint(x: x - r * 1.5, y: y + r * 0.4))
            OpusTheme.sweat.setFill()
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
        NSGraphicsContext.restoreGraphicsState()
    }

    /// A cone tilted to the left on top of the head, with a pompom; Santa's
    /// gets a white band, the party one two dots.
    private static func drawHat(_ hat: Hat, center: NSPoint, s: CGFloat, knockout: Bool) {
        let tilt: CGFloat = 0.35
        let base = NSPoint(x: center.x - s * 0.03, y: center.y + s * 0.2)
        let half = s * 0.19, height = s * 0.3
        func at(_ dx: CGFloat, _ dy: CGFloat) -> NSPoint {
            NSPoint(x: base.x + dx * cos(tilt) - dy * sin(tilt), y: base.y + dx * sin(tilt) + dy * cos(tilt))
        }
        let cone = NSBezierPath()
        cone.move(to: at(-half, 0))
        cone.line(to: at(half, 0))
        cone.line(to: at(0, height))
        cone.close()
        let fill: NSColor, trim: NSColor
        switch hat {
        case .nightcap: fill = OpusTheme.nightcap; trim = OpusTheme.cream
        case .santa: fill = OpusTheme.santa; trim = OpusTheme.cream
        case .party: fill = OpusTheme.amber; trim = OpusTheme.red
        }
        (knockout ? NSColor.black : fill).setFill()
        cone.fill()
        if hat == .santa {
            let band = NSBezierPath()
            band.lineWidth = s * 0.07
            band.lineCapStyle = .round
            band.move(to: at(-half * 1.05, 0))
            band.line(to: at(half * 1.05, 0))
            (knockout ? NSColor.black : trim).setStroke()
            band.stroke()
        }
        if hat == .party, !knockout, s >= detailMinSide {
            OpusTheme.cyan.setFill()
            for (dx, dy) in [(-half * 0.3, height * 0.28), (half * 0.15, height * 0.55)] as [(CGFloat, CGFloat)] {
                let dot = at(dx, dy), r = s * 0.025
                NSBezierPath(ovalIn: NSRect(x: dot.x - r, y: dot.y - r, width: r * 2, height: r * 2)).fill()
            }
        }
        let tip = at(0, height), r = s * 0.055
        (knockout ? NSColor.black : trim).setFill()
        NSBezierPath(ovalIn: NSRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)).fill()
    }

    /// The square in `bounds` where every pose fits: rays reach about 0.52
    /// of the side from the center and a hop lifts it by up to 0.12, so 0.78
    /// of the bounds, set a little low to leave the hop its room.
    static func fittedRect(in bounds: NSRect) -> NSRect {
        let side = min(bounds.width, bounds.height) * 0.78
        return NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2 - side * 0.06, width: side, height: side)
    }

    /// The avatar alone as an image, fitted so no pose is cut (the menu bar).
    static func image(_ pose: Pose, color: NSColor, size: CGFloat, knockout: Bool = false) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(pose, color: color, in: fittedRect(in: rect), knockout: knockout)
            return true
        }
    }
}

extension ClaudeAvatar {
    /// The avatar as PNG bytes, `size` pixels square on a clear ground, fitted
    /// so no pose is cut (a notification's thumbnail).
    static func pngData(_ pose: Pose, color: NSColor, size: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        draw(pose, color: color, in: fittedRect(in: NSRect(x: 0, y: 0, width: size, height: size)))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

/// A button that says when the pointer enters and leaves it, so something
/// beside it can react (the ended session's sleeper wakes up).
final class HoverButton: NSButton {
    var onHover: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }
}

/// An avatar that animates itself, for surfaces with room for one. The
/// avatar takes the lower part of the view and leaves the top for the "z"s.
final class ClaudeAvatarView: NSView {
    var color: NSColor = OpusTheme.cream(0.6) { didSet { needsDisplay = true } }
    var pose: (Double) -> ClaudeAvatar.Pose? = { ClaudeAvatar.sleeping(time: $0) } {
        didSet { needsDisplay = true }
    }
    /// Off for a pose that holds still: no frames are drawn for it.
    var animates = true
    /// Keep the top of the view for the "z"s; off, the avatar fills it, centered.
    var snoreRoom = true { didSet { needsDisplay = true } }
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        // Always ticking while in a window, so switching Animate Claude or
        // reduce motion takes effect at once; held still, a tick draws
        // the resting pose once and then does nothing.
        var drewStill = false
        let timer = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            guard let self, self.animates, !self.isHiddenOrHasHiddenAncestor,
                  self.window?.occlusionState.contains(.visible) == true else { return }
            let moving = ClaudeAvatar.motionAllowed
            guard moving || !drewStill else { return }
            drewStill = !moving
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        let still = !ClaudeAvatar.motionAllowed
        guard let pose = pose(still ? 0 : ProcessInfo.processInfo.systemUptime) else { return }
        let side = min(bounds.width, bounds.height) * 0.72
        let rect = snoreRoom ? NSRect(x: bounds.midX - side / 2, y: bounds.minY, width: side, height: side)
                             : ClaudeAvatar.fittedRect(in: bounds)
        ClaudeAvatar.draw(pose, color: color, in: rect)
    }
}
