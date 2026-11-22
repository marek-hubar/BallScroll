import Foundation
import Testing
@testable import BallScrollCore

private typealias Output = GestureMachine.Output
private typealias Phase = GestureMachine.Phase

/// Drives a GestureMachine the way the app does: ball reports arrive at the
/// device's rate, frames tick at the display's rate, all on one clock.
private struct Rig {
    var machine: GestureMachine
    var time = 100.0
    var outputs: [Output] = []
    var swallowed: [Bool] = []
    let frameInterval = 1.0 / 60.0
    private var nextFrame = 100.0

    init(_ configure: (inout ScrollSettings) -> Void = { _ in }) {
        var settings = ScrollSettings()
        // Tests start from the simplest behaviour and opt in to the rest.
        settings.speed = 2
        settings.acceleration = 0
        settings.smoothing = 0
        settings.deadZone = 3
        settings.axisLock = false
        settings.momentum = false
        configure(&settings)
        machine = GestureMachine(settings: settings)
    }

    mutating func press() {
        record(machine.triggerDown(at: time))
    }

    mutating func release() {
        record(machine.triggerUp(at: time))
    }

    /// Roll the ball: `reports` movements of (dx, dy) counts, one every `interval` seconds.
    mutating func roll(dx: Double = 0, dy: Double = 0, reports: Int = 1, interval: Double = 0.008) {
        for _ in 0..<reports {
            advance(interval)
            record(machine.move(dx: dx, dy: dy, at: time))
        }
    }

    /// Let time pass, running display frames as it does.
    mutating func advance(_ seconds: Double) {
        let end = time + seconds
        while nextFrame <= end {
            time = nextFrame
            if machine.needsFrames {
                outputs += machine.frame(at: time)
            }
            nextFrame += frameInterval
        }
        time = end
    }

    private mutating func record(_ reaction: GestureMachine.Reaction) {
        outputs += reaction.outputs
        swallowed.append(reaction.swallow)
    }

    var scrolls: [(dx: Int, dy: Int, phase: Phase)] {
        outputs.compactMap {
            if case let .scroll(dx, dy, phase) = $0 { return (dx, dy, phase) }
            return nil
        }
    }

    var phases: [Phase] { scrolls.map(\.phase) }
    var totalDY: Int { scrolls.reduce(0) { $0 + $1.dy } }
    var totalDX: Int { scrolls.reduce(0) { $0 + $1.dx } }

    func total(in wanted: Set<Phase>) -> Int {
        scrolls.filter { wanted.contains($0.phase) }.reduce(0) { $0 + $1.dy }
    }
}

@Suite("Click versus scroll")
struct ClickTests {
    @Test("A press released without rolling is replayed as a click")
    func plainClick() {
        var rig = Rig()
        rig.press()
        rig.advance(0.1)
        rig.release()
        #expect(rig.outputs == [.freezePointer, .releasePointer, .click])
        #expect(rig.swallowed == [true, true])
        #expect(rig.machine.isIdle)
    }

    @Test("Jitter inside the Dead Zone still clicks")
    func jitterStillClicks() {
        var rig = Rig { $0.deadZone = 3 }
        rig.press()
        rig.roll(dx: 1, dy: 1)
        rig.roll(dx: -1, dy: 1)
        rig.release()
        #expect(rig.outputs == [.freezePointer, .releasePointer, .click])
        #expect(rig.swallowed.allSatisfy { $0 })
    }

    @Test("The Dead Zone measures net displacement, not path length")
    func backAndForthStaysInDeadZone() {
        var rig = Rig { $0.deadZone = 3 }
        rig.press()
        for _ in 0..<10 {
            rig.roll(dy: 2)
            rig.roll(dy: -2)
        }
        rig.release()
        #expect(rig.outputs.contains(.click))
        #expect(rig.scrolls.isEmpty)
    }

    @Test("Rolling past the Dead Zone scrolls and never clicks")
    func scrollSuppressesClick() {
        var rig = Rig { $0.deadZone = 3 }
        rig.press()
        rig.roll(dy: 2, reports: 5)
        rig.advance(0.05)
        rig.release()
        #expect(!rig.outputs.contains(.click))
        #expect(!rig.scrolls.isEmpty)
    }

    @Test("With a Dead Zone of zero, a single count scrolls")
    func zeroDeadZone() {
        var rig = Rig { $0.deadZone = 0 }
        rig.press()
        rig.roll(dy: 1)
        rig.advance(0.05)
        rig.release()
        #expect(!rig.outputs.contains(.click))
        #expect(rig.totalDY == 2)
    }

    @Test("With a Dead Zone of zero, a still press is still a click")
    func zeroDeadZoneClick() {
        var rig = Rig { $0.deadZone = 0 }
        rig.press()
        rig.release()
        #expect(rig.outputs.contains(.click))
    }

    @Test("Movement and release are passed through when no gesture is active")
    func idlePassesThrough() {
        var rig = Rig()
        rig.roll(dy: 5, reports: 3)
        rig.release()
        #expect(rig.outputs.isEmpty)
        #expect(rig.swallowed.allSatisfy { !$0 })
    }
}

@Suite("Scrolling")
struct ScrollingTests {
    @Test("A gesture is began, changed..., ended")
    func phaseOrder() {
        var rig = Rig()
        rig.press()
        rig.roll(dy: 3, reports: 20)
        rig.advance(0.2)
        rig.release()
        let phases = rig.phases
        #expect(phases.first == .began)
        #expect(phases.last == .ended)
        #expect(phases.dropFirst().dropLast().allSatisfy { $0 == .changed })
        #expect(phases.count > 3)
        #expect(rig.outputs.last == .releasePointer)
    }

    @Test("Every pixel of ball movement is scrolled, none lost or invented")
    func pixelConservation() {
        var rig = Rig { $0.speed = 1.3; $0.deadZone = 0 }
        rig.press()
        rig.roll(dy: 1, reports: 137, interval: 0.011)
        rig.release()
        let expected = 137 * 1.3
        #expect(abs(Double(rig.totalDY) - expected) <= 0.5)
    }

    @Test("Smoothing delays pixels but does not change the total")
    func smoothingConserves() {
        var rig = Rig { $0.speed = 2.5; $0.deadZone = 0; $0.smoothing = 0.05 }
        rig.press()
        rig.roll(dy: 3, reports: 40)
        rig.release()
        #expect(abs(Double(rig.totalDY) - 40 * 3 * 2.5) <= 0.5)
    }

    @Test("Smoothing spreads one ball report over several frames")
    func smoothingSpreads() {
        var rig = Rig { $0.speed = 10; $0.deadZone = 0; $0.smoothing = 0.05 }
        rig.press()
        rig.roll(dy: 10)
        rig.advance(0.5)
        let moving = rig.scrolls.filter { $0.dy != 0 }
        #expect(moving.count >= 4)
        #expect(rig.totalDY == 100)
        // Each frame takes a smaller share than the one before.
        #expect(moving.map(\.dy) == moving.map(\.dy).sorted(by: >))
    }

    @Test("Without smoothing, a ball report is scrolled in the next frame")
    func noSmoothingIsImmediate() {
        var rig = Rig { $0.speed = 10; $0.deadZone = 0 }
        rig.press()
        rig.roll(dy: 10)
        rig.advance(0.02)
        #expect(rig.scrolls.count == 1)
        #expect(rig.totalDY == 100)
    }

    @Test("Slow rolling accumulates sub-pixel movement instead of dropping it")
    func subPixelAccumulation() {
        var rig = Rig { $0.speed = 0.25; $0.deadZone = 0 }
        rig.press()
        rig.roll(dy: 1, reports: 40, interval: 0.05)
        rig.release()
        #expect(rig.totalDY == 10)
    }

    @Test("Content follows the ball by default and each axis can be reversed")
    func direction() {
        var natural = Rig { $0.deadZone = 0 }
        natural.press()
        natural.roll(dx: 4, dy: 4, reports: 10)
        natural.release()
        #expect(natural.totalDY > 0)
        #expect(natural.totalDX > 0)

        var reversed = Rig { $0.deadZone = 0; $0.reverseVertical = true }
        reversed.press()
        reversed.roll(dx: 4, dy: 4, reports: 10)
        reversed.release()
        #expect(reversed.totalDY == -natural.totalDY)
        #expect(reversed.totalDX == natural.totalDX)
    }

    @Test("Acceleration scrolls further per count when the ball moves fast")
    func acceleration() {
        func distance(interval: Double) -> Int {
            var rig = Rig { $0.deadZone = 0; $0.acceleration = 1 }
            rig.press()
            rig.roll(dy: 5, reports: 40, interval: interval)
            rig.release()
            return rig.totalDY
        }
        let slow = distance(interval: 0.05)
        let fast = distance(interval: 0.004)
        #expect(fast > slow * 3 / 2)
    }
}

@Suite("Axis Lock")
struct AxisLockTests {
    @Test("A mostly vertical roll scrolls only vertically")
    func locksVertical() {
        var rig = Rig { $0.axisLock = true }
        rig.press()
        rig.roll(dx: 1, dy: 4, reports: 30)
        rig.release()
        #expect(rig.totalDX == 0)
        #expect(rig.totalDY > 0)
    }

    @Test("A mostly horizontal roll scrolls only horizontally")
    func locksHorizontal() {
        var rig = Rig { $0.axisLock = true }
        rig.press()
        rig.roll(dx: -5, dy: 1, reports: 30)
        rig.release()
        #expect(rig.totalDY == 0)
        #expect(rig.totalDX < 0)
    }

    @Test("The locked axis holds until release even if the ball changes direction")
    func lockHoldsForWholeGesture() {
        var rig = Rig { $0.axisLock = true }
        rig.press()
        rig.roll(dy: 4, reports: 10)
        let before = rig.totalDX
        rig.roll(dx: 6, reports: 30)
        rig.release()
        #expect(before == 0)
        #expect(rig.totalDX == 0)
    }

    @Test("Each press chooses its axis afresh")
    func lockResetsBetweenGestures() {
        var rig = Rig { $0.axisLock = true }
        rig.press()
        rig.roll(dy: 4, reports: 10)
        rig.release()
        rig.press()
        rig.roll(dx: 4, reports: 10)
        rig.release()
        #expect(rig.totalDX > 0)
    }

    @Test("With Axis Lock off both axes scroll together")
    func freeScrolling() {
        var rig = Rig { $0.axisLock = false }
        rig.press()
        rig.roll(dx: 2, dy: 4, reports: 30)
        rig.release()
        #expect(rig.totalDX > 0)
        #expect(rig.totalDY > 0)
    }
}

@Suite("Momentum")
struct MomentumTests {
    /// A quick flick: about 1500 counts per second for a tenth of a second.
    private func flick(_ rig: inout Rig) {
        rig.press()
        rig.roll(dy: 12, reports: 12)
        rig.release()
    }

    @Test("Releasing mid-roll glides: ended, then momentum began, changed..., ended")
    func glidePhases() {
        var rig = Rig { $0.momentum = true }
        flick(&rig)
        rig.advance(5)
        let phases = rig.phases
        let endedAt = phases.firstIndex(of: .ended)!
        let glide = Array(phases[(endedAt + 1)...])
        #expect(glide.first == .momentumBegan)
        #expect(glide.last == .momentumEnded)
        #expect(glide.dropFirst().dropLast().allSatisfy { $0 == .momentumChanged })
        #expect(rig.machine.isIdle)
        #expect(!rig.machine.needsFrames)
    }

    @Test("The glide decays and travels about velocity times the glide time")
    func glideDistance() {
        var rig = Rig { $0.momentum = true; $0.momentumGlide = 0.4 }
        flick(&rig)
        rig.advance(5)
        let glide = rig.scrolls.filter { $0.phase == .momentumBegan || $0.phase == .momentumChanged }.map(\.dy)
        // 12 counts * 2 px every 8 ms = 3000 px/s; distance is about v * tau = 1200 px.
        let distance = glide.reduce(0, +)
        #expect(distance > 1000 && distance < 1400)
        // The first glide frame only covers the time since the release, so it is
        // short. From then on the decay is monotonic, give or take a rounding pixel.
        let full = Array(glide.dropFirst())
        for (a, b) in zip(full, full.dropFirst()) {
            #expect(b <= a + 1)
        }
        #expect(full.first! > full.last! * 10)
    }

    @Test("A longer glide setting travels further")
    func glideSetting() {
        func distance(_ tau: Double) -> Int {
            var rig = Rig { $0.momentum = true; $0.momentumGlide = tau }
            flick(&rig)
            rig.advance(8)
            return rig.total(in: [.momentumBegan, .momentumChanged])
        }
        #expect(distance(0.6) > distance(0.2) * 2)
    }

    @Test("No glide when Momentum is off")
    func momentumOff() {
        var rig = Rig { $0.momentum = false }
        flick(&rig)
        rig.advance(2)
        #expect(rig.phases.last == .ended)
        #expect(rig.machine.isIdle)
    }

    @Test("No glide when the ball stopped before the release")
    func stoppedBallDoesNotGlide() {
        var rig = Rig { $0.momentum = true }
        rig.press()
        rig.roll(dy: 12, reports: 12)
        rig.advance(0.2)
        rig.release()
        rig.advance(2)
        #expect(rig.phases.last == .ended)
        #expect(rig.outputs.last == .releasePointer)
    }

    @Test("No glide after a slow roll")
    func slowRollDoesNotGlide() {
        var rig = Rig { $0.momentum = true }
        rig.press()
        rig.roll(dy: 1, reports: 30, interval: 0.02)
        rig.release()
        rig.advance(2)
        #expect(rig.phases.last == .ended)
    }

    @Test("The pointer stays frozen while the ball is still rolling after release")
    func ballSettling() {
        var rig = Rig { $0.momentum = true }
        flick(&rig)
        let afterRelease = rig.outputs.count
        // The ball keeps spinning for 50 ms: swallowed, pointer still frozen.
        rig.swallowed.removeAll()
        rig.roll(dy: 6, reports: 6)
        #expect(rig.swallowed.allSatisfy { $0 })
        #expect(!rig.outputs[afterRelease...].contains(.releasePointer))
        // Then it rests, and the pointer is freed while the glide continues.
        rig.advance(0.15)
        #expect(rig.outputs[afterRelease...].contains(.releasePointer))
        #expect(rig.machine.needsFrames)
    }

    @Test("The pointer is freed after a timeout even if the ball never rests")
    func settleTimeout() {
        var rig = Rig { $0.momentum = true; $0.momentumGlide = 0.8 }
        flick(&rig)
        let afterRelease = rig.outputs.count
        rig.roll(dy: 3, reports: 100) // 0.8 s of continuous rolling
        #expect(rig.outputs[afterRelease...].contains(.releasePointer))
    }

    @Test("Moving the ball after it settled stops the glide and moves the pointer")
    func movementStopsGlide() {
        var rig = Rig { $0.momentum = true; $0.momentumGlide = 0.8 }
        flick(&rig)
        rig.advance(0.3)
        #expect(rig.machine.needsFrames)
        rig.swallowed.removeAll()
        rig.roll(dx: 4, reports: 3)
        #expect(rig.phases.last == .momentumEnded)
        #expect(rig.machine.isIdle)
        #expect(rig.swallowed.last == false)
    }

    @Test("Another button or a real wheel stops the glide")
    func interruptStopsGlide() {
        var rig = Rig { $0.momentum = true; $0.momentumGlide = 0.8 }
        flick(&rig)
        rig.advance(0.3)
        rig.outputs += rig.machine.interrupt()
        #expect(rig.phases.last == .momentumEnded)
        #expect(rig.machine.isIdle)
    }

    @Test("Pressing the Trigger Button during a glide stops it and starts a new gesture")
    func pressDuringGlide() {
        var rig = Rig { $0.momentum = true; $0.momentumGlide = 0.8 }
        flick(&rig)
        rig.advance(0.3)
        rig.press()
        #expect(rig.phases.last == .momentumEnded)
        rig.release()
        #expect(rig.outputs.last == .click)
    }

    @Test("Freeze and release of the pointer always pair up")
    func freezeReleaseBalance() {
        var rig = Rig { $0.momentum = true }
        for _ in 0..<5 {
            flick(&rig)
            rig.advance(0.05)
        }
        rig.advance(5)
        var frozen = false
        for output in rig.outputs {
            if output == .freezePointer {
                #expect(!frozen)
                frozen = true
            } else if output == .releasePointer {
                #expect(frozen)
                frozen = false
            }
        }
        #expect(!frozen)
    }
}

@Suite("Cancelling")
struct CancelTests {
    @Test("Cancelling mid-scroll ends the gesture and swallows the later release")
    func cancelWhileScrolling() {
        var rig = Rig()
        rig.press()
        rig.roll(dy: 4, reports: 10)
        rig.advance(0.05)
        rig.outputs += rig.machine.cancel()
        #expect(rig.phases.last == .ended)
        #expect(rig.outputs.last == .releasePointer)
        rig.swallowed.removeAll()
        rig.release()
        #expect(rig.swallowed == [true])
        #expect(!rig.outputs.contains(.click))
    }

    @Test("Cancelling a held press releases the pointer without clicking")
    func cancelWhilePending() {
        var rig = Rig()
        rig.press()
        rig.outputs += rig.machine.cancel()
        rig.release()
        #expect(rig.outputs == [.freezePointer, .releasePointer])
    }

    @Test("Interrupting while the button is held does not disturb the gesture")
    func interruptWhileScrolling() {
        var rig = Rig()
        rig.press()
        rig.roll(dy: 4, reports: 10)
        #expect(rig.machine.interrupt().isEmpty)
        #expect(rig.machine.needsFrames)
    }

    @Test("Saved settings from an older version load with defaults for new fields")
    func settingsDecodeDefaults() throws {
        let json = Data(#"{"speed": 3.5, "axisLock": false}"#.utf8)
        let settings = try JSONDecoder().decode(ScrollSettings.self, from: json)
        #expect(settings.speed == 3.5)
        #expect(settings.axisLock == false)
        #expect(settings.momentum == ScrollSettings().momentum)
        #expect(settings.deadZone == ScrollSettings().deadZone)
    }
}
