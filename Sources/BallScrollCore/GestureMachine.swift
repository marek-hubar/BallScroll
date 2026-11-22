import Foundation

/// Turns Trigger Button presses and ball movement into scroll output.
///
/// The machine is pure: it never touches the system. The caller feeds it
/// inputs with timestamps (seconds, any monotonic clock) and carries out the
/// `Output`s it returns. That keeps every rule of Ball Scrolling testable
/// without a mouse.
///
/// Lifecycle of one gesture:
///
///     idle ── triggerDown ──▶ pending ── leaves Dead Zone ──▶ scrolling
///      ▲                         │                              │
///      │                    triggerUp                       triggerUp
///      │                     (click)                            │
///      │                         ▼                   fast enough + Momentum on
///      └─────────────────────────┴──────────◀── momentum ◀──────┘
public struct GestureMachine: Sendable {
    public typealias Vec = SIMD2<Double>

    public enum Phase: Equatable, Sendable {
        case began, changed, ended
        case momentumBegan, momentumChanged, momentumEnded
    }

    public enum Output: Equatable, Sendable {
        /// Hold the pointer where it is until `releasePointer`.
        case freezePointer
        case releasePointer
        /// Replay the held-back Trigger Button click (press and release).
        case click
        /// Scroll by whole pixels. Positive `dy` moves content down, positive
        /// `dx` moves content right (the Core Graphics wheel convention).
        case scroll(dx: Int, dy: Int, phase: Phase)
    }

    public struct Reaction: Equatable, Sendable {
        public var outputs: [Output] = []
        /// Whether the input event must be hidden from the rest of the system.
        public var swallow: Bool = false
    }

    /// Constants that are not user settings.
    public enum Tuning {
        /// Ball travel after which the Axis Lock stops reconsidering its axis.
        public static let axisDecisionDistance = 8.0
        /// Window for measuring ball speed for acceleration, seconds.
        public static let accelerationWindow = 0.05
        /// Ball speed (counts/s) beyond which acceleration stops growing.
        public static let accelerationSpeedCap = 4000.0
        /// Window for measuring scroll velocity at release, seconds.
        public static let releaseVelocityWindow = 0.08
        /// Minimum release velocity (px/s) that starts Momentum.
        public static let momentumStartSpeed = 300.0
        /// Momentum ends when it has slowed to this speed (px/s).
        public static let momentumStopSpeed = 40.0
        public static let momentumMaxSpeed = 8000.0
        /// After a release into Momentum the ball is usually still rolling.
        /// The pointer stays frozen until the ball has been still this long...
        public static let ballSettleTime = 0.08
        /// ...or until this much time has passed, whichever comes first.
        public static let ballSettleTimeout = 0.6
        /// Ball travel, after settling, that stops Momentum.
        public static let momentumCancelTravel = 3.0
    }

    public var settings: ScrollSettings

    private enum Axis: Sendable { case horizontal, vertical }

    private struct Sample: Sendable {
        var time: Double
        var pixels: Vec
        var counts: Double
    }

    private struct Scroll: Sendable {
        var start: Double
        var began = false
        var lockTravel = Vec.zero
        var axis: Axis?
        var axisDecided = false
        /// Pixels accepted from the ball but not yet handed to a frame.
        var pending = Vec.zero
        /// Sub-pixel carry, always within half a pixel of zero.
        var remainder = Vec.zero
        var samples: [Sample] = []
        var lastFrame: Double?
        var lastMove: Double
    }

    private struct Glide: Sendable {
        var velocity: Vec
        var start: Double
        var elapsed = 0.0
        var began = false
        var remainder: Vec
        /// True while waiting for the ball to come to rest after release.
        var settling = true
        var lastMove: Double
        var travel = 0.0
    }

    private enum State: Sendable {
        case idle
        case pending(net: Vec)
        case scrolling(Scroll)
        case momentum(Glide)
    }

    private var state: State = .idle
    private var pointerFrozen = false
    /// Set when a gesture was cancelled while the button was still down, so
    /// the matching release is swallowed too.
    private var awaitingRelease = false

    public init(settings: ScrollSettings = ScrollSettings()) {
        self.settings = settings
    }

    // MARK: - State queries

    public var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    /// True while `frame(at:)` should be called once per display refresh.
    public var needsFrames: Bool {
        switch state {
        case .scrolling, .momentum: return true
        case .idle, .pending: return false
        }
    }

    // MARK: - Inputs

    public mutating func triggerDown(at time: Double) -> Reaction {
        var reaction = Reaction(swallow: true)
        switch state {
        case .pending, .scrolling:
            return reaction // duplicate press; nothing new to do
        case .momentum(let glide):
            endMomentum(glide, releasingPointer: false, into: &reaction.outputs)
        case .idle:
            break
        }
        awaitingRelease = false
        freeze(into: &reaction.outputs)
        state = .pending(net: .zero)
        return reaction
    }

    public mutating func triggerUp(at time: Double) -> Reaction {
        var reaction = Reaction()
        switch state {
        case .pending:
            reaction.swallow = true
            release(into: &reaction.outputs)
            reaction.outputs.append(.click)
            state = .idle

        case .scrolling(var scroll):
            reaction.swallow = true
            // Hand over whatever the smoothing was still holding back.
            let rest = scroll.pending
            scroll.pending = .zero
            emit(rest, from: &scroll, into: &reaction.outputs)
            if scroll.began {
                reaction.outputs.append(.scroll(dx: 0, dy: 0, phase: .ended))
            }
            let velocity = releaseVelocity(of: scroll, at: time)
            if settings.momentum, scroll.began, length(velocity) >= Tuning.momentumStartSpeed {
                state = .momentum(Glide(
                    velocity: clampLength(velocity, Tuning.momentumMaxSpeed),
                    start: time,
                    remainder: scroll.remainder,
                    lastMove: scroll.lastMove
                ))
            } else {
                release(into: &reaction.outputs)
                state = .idle
            }

        case .idle, .momentum:
            // We did not swallow the matching press, unless a gesture was cancelled mid-hold.
            reaction.swallow = awaitingRelease
            awaitingRelease = false
        }
        return reaction
    }

    /// Ball movement in device counts. Positive `dy` is the ball rolling toward the user
    /// (pointer moving down the screen).
    public mutating func move(dx: Double, dy: Double, at time: Double) -> Reaction {
        var reaction = Reaction()
        let delta = Vec(dx, dy)
        switch state {
        case .idle:
            break

        case .pending(var net):
            reaction.swallow = true
            net += delta
            let travel = length(net)
            if travel > settings.deadZone, travel > 0 {
                // Movement inside the Dead Zone is discarded; scrolling starts with this event.
                var scroll = Scroll(start: time, lastMove: time)
                ingest(delta, into: &scroll, at: time)
                state = .scrolling(scroll)
            } else {
                state = .pending(net: net)
            }

        case .scrolling(var scroll):
            reaction.swallow = true
            ingest(delta, into: &scroll, at: time)
            state = .scrolling(scroll)

        case .momentum(var glide):
            if glide.settling {
                // The ball is still rolling from the flick: not a new intention.
                reaction.swallow = true
                glide.lastMove = time
                state = .momentum(glide)
            } else {
                glide.travel += length(delta)
                if glide.travel >= Tuning.momentumCancelTravel {
                    endMomentum(glide, releasingPointer: true, into: &reaction.outputs)
                    state = .idle
                } else {
                    state = .momentum(glide)
                }
            }
        }
        return reaction
    }

    /// Call once per display refresh while `needsFrames` is true.
    public mutating func frame(at time: Double) -> [Output] {
        var outputs: [Output] = []
        switch state {
        case .idle, .pending:
            break

        case .scrolling(var scroll):
            let dt = min(max(time - (scroll.lastFrame ?? time - 1.0 / 60.0), 1.0 / 480.0), 0.1)
            scroll.lastFrame = time
            var share = scroll.pending
            if settings.smoothing > 0.0005 {
                share = scroll.pending * (1 - exp(-dt / settings.smoothing))
                // Do not let an invisible tail trickle out forever.
                if length(scroll.pending - share) < 0.05 { share = scroll.pending }
            }
            scroll.pending -= share
            emit(share, from: &scroll, into: &outputs)
            state = .scrolling(scroll)

        case .momentum(var glide):
            let tau = max(settings.momentumGlide, 0.05)
            let elapsed = max(time - glide.start, glide.elapsed)
            // Exact integral of v0 * e^(-t/tau) over this frame.
            let distance = glide.velocity * (tau * (exp(-glide.elapsed / tau) - exp(-elapsed / tau)))
            glide.elapsed = elapsed
            glide.remainder += distance
            let whole = glide.remainder.rounded(.toNearestOrAwayFromZero)
            glide.remainder -= whole
            if whole != .zero {
                outputs.append(.scroll(
                    dx: Int(whole.x), dy: Int(whole.y),
                    phase: glide.began ? .momentumChanged : .momentumBegan
                ))
                glide.began = true
            }
            if glide.settling,
               time - glide.lastMove >= Tuning.ballSettleTime || elapsed >= Tuning.ballSettleTimeout {
                glide.settling = false
                release(into: &outputs)
            }
            if length(glide.velocity) * exp(-elapsed / tau) < Tuning.momentumStopSpeed {
                endMomentum(glide, releasingPointer: true, into: &outputs)
                state = .idle
            } else {
                state = .momentum(glide)
            }
        }
        return outputs
    }

    /// Something else happened that should stop a glide: another button, a real
    /// wheel, a key press. Does nothing while the Trigger Button is held.
    public mutating func interrupt() -> [Output] {
        var outputs: [Output] = []
        if case .momentum(let glide) = state {
            endMomentum(glide, releasingPointer: true, into: &outputs)
            state = .idle
        }
        return outputs
    }

    /// Abandon whatever is in progress, for example when Ball Scrolling is
    /// paused or an Excluded App comes to the front mid-gesture.
    public mutating func cancel() -> [Output] {
        var outputs: [Output] = []
        switch state {
        case .idle:
            break
        case .pending:
            awaitingRelease = true
        case .scrolling(let scroll):
            awaitingRelease = true
            if scroll.began {
                outputs.append(.scroll(dx: 0, dy: 0, phase: .ended))
            }
        case .momentum(let glide):
            endMomentum(glide, releasingPointer: false, into: &outputs)
        }
        release(into: &outputs)
        state = .idle
        return outputs
    }

    // MARK: - Internals

    private mutating func freeze(into outputs: inout [Output]) {
        guard !pointerFrozen else { return }
        pointerFrozen = true
        outputs.append(.freezePointer)
    }

    private mutating func release(into outputs: inout [Output]) {
        guard pointerFrozen else { return }
        pointerFrozen = false
        outputs.append(.releasePointer)
    }

    private mutating func endMomentum(_ glide: Glide, releasingPointer: Bool, into outputs: inout [Output]) {
        if glide.began {
            outputs.append(.scroll(dx: 0, dy: 0, phase: .momentumEnded))
        }
        if releasingPointer {
            release(into: &outputs)
        }
    }

    /// Convert one ball movement into pixels and queue it for the next frames.
    private func ingest(_ rawDelta: Vec, into scroll: inout Scroll, at time: Double) {
        var delta = rawDelta
        scroll.lastMove = time

        if settings.axisLock {
            if !scroll.axisDecided {
                scroll.lockTravel += delta
                let t = scroll.lockTravel
                scroll.axis = abs(t.x) > abs(t.y) ? .horizontal : .vertical
                if length(t) >= Tuning.axisDecisionDistance {
                    scroll.axisDecided = true
                }
            }
            switch scroll.axis {
            case .horizontal: delta.y = 0
            case .vertical, .none: delta.x = 0
            }
        }

        // Ball speed over a short window, in counts per second, drives acceleration.
        let counts = length(delta)
        let windowStart = time - Tuning.accelerationWindow
        let recentCounts = scroll.samples.reduce(counts) { $1.time > windowStart ? $0 + $1.counts : $0 }
        let ballSpeed = min(recentCounts / Tuning.accelerationWindow, Tuning.accelerationSpeedCap)
        let gain = settings.speed * (1 + max(settings.acceleration, 0) * ballSpeed / 1000)

        var pixels = delta * gain
        if settings.reverseVertical { pixels.y = -pixels.y }
        if settings.reverseHorizontal { pixels.x = -pixels.x }

        scroll.pending += pixels
        scroll.samples.append(Sample(time: time, pixels: pixels, counts: counts))
        let horizon = time - 0.25
        if let first = scroll.samples.first, first.time < horizon {
            scroll.samples.removeAll { $0.time < horizon }
        }
    }

    /// Add fractional pixels to the carry and output the whole pixels.
    private func emit(_ pixels: Vec, from scroll: inout Scroll, into outputs: inout [Output]) {
        scroll.remainder += pixels
        let whole = scroll.remainder.rounded(.toNearestOrAwayFromZero)
        guard whole != .zero else { return }
        scroll.remainder -= whole
        outputs.append(.scroll(dx: Int(whole.x), dy: Int(whole.y), phase: scroll.began ? .changed : .began))
        scroll.began = true
    }

    private func releaseVelocity(of scroll: Scroll, at time: Double) -> Vec {
        let window = min(max(time - scroll.start, 0.03), Tuning.releaseVelocityWindow)
        let windowStart = time - window
        let travelled = scroll.samples.reduce(Vec.zero) { $1.time > windowStart ? $0 + $1.pixels : $0 }
        return travelled / window
    }

    private func length(_ v: Vec) -> Double {
        (v * v).sum().squareRoot()
    }

    private func clampLength(_ v: Vec, _ limit: Double) -> Vec {
        let l = length(v)
        return l > limit ? v * (limit / l) : v
    }
}
