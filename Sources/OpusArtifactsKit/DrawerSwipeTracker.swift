// DrawerSwipeTracker: reads a trackpad (or Magic Mouse) scroll gesture
// over the terminal as a drawer swipe, or leaves it to the terminal.
//
// Right pulls Copy in from the left edge, left pulls Artifacts in from the
// right, and with a drawer open the swipe toward its edge closes it. The
// drawer follows the fingers; on release it settles open past a third of
// its width or on a fling, closed otherwise.
//
// Scrolling comes first. The axis is decided once per gesture, after a few
// points of travel, and only a movement at least twice as horizontal as it
// is vertical counts; everything else, including the momentum that follows
// a vertical flick, passes through untouched.

import CoreGraphics
import Foundation

public struct DrawerSwipeTracker {
    public enum Phase: Sendable { case began, changed, ended, cancelled, momentum }

    public enum Output: Equatable, Sendable {
        /// Not a drawer swipe: the event belongs to whatever is under it.
        case passThrough
        /// A drawer swipe's own event that moves nothing (its momentum).
        case consume
        /// Where the drawer should be under the fingers, 0 parked to 1 in.
        case progress(DrawerGeometry.Occupant, CGFloat)
        /// The fingers lifted: settle the drawer open or closed.
        case finish(DrawerGeometry.Occupant, open: Bool)
    }

    public static let axisLockDistance: CGFloat = 8
    public static let horizontalRatio: CGFloat = 2
    public static let commitFraction: CGFloat = 1.0 / 3.0
    /// Points per second, in the finger's direction.
    public static let flingVelocity: CGFloat = 500
    /// A move older than this when the fingers lift does not count as a fling.
    public static let flingWindow: TimeInterval = 0.08

    private enum State {
        case idle
        case undecided
        /// Not ours: vertical, or horizontal the way no drawer goes.
        case notOurs
        case swiping(target: DrawerGeometry.Occupant, opening: Bool)
        /// Lifted; its momentum is consumed or passed by what it was.
        case lifted(wasSwipe: Bool)
    }

    private var state: State = .idle
    private var sumX: CGFloat = 0
    private var sumY: CGFloat = 0
    /// The last two (time, sumX) samples, for the release velocity.
    private var samples: [(time: TimeInterval, x: CGFloat)] = []

    public init() {}

    /// The scroll delta turned into the direction the fingers moved, whether
    /// or not the person scrolls "naturally".
    public static func fingerDX(scrollingDeltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? scrollingDeltaX : -scrollingDeltaX
    }

    /// `width` answers each drawer's current width: which drawer a swipe
    /// moves is only known once its direction is.
    public mutating func feed(phase: Phase, fingerDX: CGFloat, dy: CGFloat, time: TimeInterval,
                              open: DrawerGeometry.Occupant,
                              width: (DrawerGeometry.Occupant) -> CGFloat) -> Output {
        switch phase {
        case .momentum:
            if case .lifted(true) = state { return .consume }
            return .passThrough

        case .began:
            state = .undecided
            sumX = 0
            sumY = 0
            samples = []
            return track(fingerDX, dy, time, open, width)

        case .changed:
            switch state {
            case .idle, .lifted: return .passThrough
            default: return track(fingerDX, dy, time, open, width)
            }

        case .ended:
            defer { samples = [] }
            guard case let .swiping(target, opening) = state else {
                state = .lifted(wasSwipe: false)
                return .passThrough
            }
            state = .lifted(wasSwipe: true)
            let travel = max(0, sumX * direction(target, opening))
            let fling = velocity(at: time) * direction(target, opening) >= Self.flingVelocity
            let farEnough = travel >= width(target) * Self.commitFraction
            return .finish(target, open: opening ? (farEnough || fling) : !(farEnough || fling))

        case .cancelled:
            guard case let .swiping(target, _) = state else {
                state = .lifted(wasSwipe: false)
                return .passThrough
            }
            state = .lifted(wasSwipe: true)
            return .finish(target, open: open == target)
        }
    }

    private mutating func track(_ dx: CGFloat, _ dy: CGFloat, _ time: TimeInterval,
                                _ open: DrawerGeometry.Occupant,
                                _ width: (DrawerGeometry.Occupant) -> CGFloat) -> Output {
        sumX += dx
        sumY += dy
        samples = Array((samples + [(time, sumX)]).suffix(2))

        if case .undecided = state {
            guard max(abs(sumX), abs(sumY)) >= Self.axisLockDistance else { return .passThrough }
            guard abs(sumX) >= Self.horizontalRatio * abs(sumY) else {
                state = .notOurs
                return .passThrough
            }
            state = Self.swipe(rightward: sumX > 0, open: open)
        }

        guard case let .swiping(target, opening) = state, width(target) > 0 else { return .passThrough }
        let travel = min(1, max(0, sumX * direction(target, opening) / width(target)))
        return .progress(target, opening ? travel : 1 - travel)
    }

    /// What a horizontal swipe does given the drawer already open.
    private static func swipe(rightward: Bool, open: DrawerGeometry.Occupant) -> State {
        switch open {
        case .none: return .swiping(target: rightward ? .reply : .artifacts, opening: true)
        case .reply: return rightward ? .notOurs : .swiping(target: .reply, opening: false)
        case .artifacts: return rightward ? .swiping(target: .artifacts, opening: false) : .notOurs
        }
    }

    /// +1 when the gesture's travel is rightward, -1 when leftward: Copy
    /// opens rightward and closes leftward, Artifacts the other way round.
    private func direction(_ target: DrawerGeometry.Occupant, _ opening: Bool) -> CGFloat {
        (target == .reply) == opening ? 1 : -1
    }

    /// The speed of the last move, or none when the fingers rested before
    /// lifting: a pull, a pause, then a release is not a fling.
    private func velocity(at liftTime: TimeInterval) -> CGFloat {
        guard samples.count == 2, samples[1].time > samples[0].time,
              liftTime - samples[1].time <= Self.flingWindow else { return 0 }
        return (samples[1].x - samples[0].x) / CGFloat(samples[1].time - samples[0].time)
    }
}
