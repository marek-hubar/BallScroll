import AppKit
import BallScrollCore
import os
import QuartzCore

/// Connects the pure `GestureMachine` to the system: it listens to pointer
/// events through an event tap, holds the pointer still, and posts the
/// resulting scroll events once per display refresh.
///
/// The tap and the display link both live on one dedicated thread, so the
/// machine is only ever touched from there and needs no locking. Settings
/// arrive from the main thread through `config`.
final class ScrollEngine: NSObject {
    struct Config: Equatable {
        var settings = ScrollSettings()
        var trigger = TriggerButton.right
        /// False while paused or while an Excluded App is frontmost.
        var active = true
    }

    /// Stamped on every event this app posts so the tap can let them through.
    static let syntheticMarker: Int64 = 0x4253_4352 // "BSCR"

    var debugLogging = false

    private let config = OSAllocatedUnfairLock(initialState: Config())
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var displayLink: CADisplayLink?
    private var linkedDisplay: CGDirectDisplayID = 0

    // Engine-thread state.
    private var machine = GestureMachine()
    private let pointer = PointerFreezer()
    private var heldPress: CGEvent?
    private var stats = GestureStats()

    var isRunning: Bool { thread != nil }

    // MARK: - Control (main thread)

    func update(_ newConfig: Config) {
        let wasActive = config.withLock { current -> Bool in
            let was = current.active
            current = newConfig
            return was
        }
        if wasActive, !newConfig.active {
            onEngineThread { [self] in
                apply(machine.cancel(), release: nil)
            }
        }
    }

    /// Starts listening. Returns false when the system refuses the event tap,
    /// which means the Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }

        let types: [CGEventType] = [
            .leftMouseDown, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: tapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        self.tap = tap
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "BallScroll engine"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        guard thread != nil, let runLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            apply(machine.cancel(), release: nil)
            displayLink?.invalidate()
            displayLink = nil
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                CFMachPortInvalidate(tap)
            }
            CFRunLoopStop(runLoop)
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        tap = nil
        tapSource = nil
        thread = nil
        self.runLoop = nil
    }

    private func onEngineThread(_ block: @escaping () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Event handling (engine thread)

    /// Returns true when the event must be hidden from the rest of the system.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The system switches a tap off if it ever responds slowly. Abandon
            // any gesture, because events were missed, and switch it back on.
            apply(machine.cancel(), release: nil)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return false
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if machine.isIdle { return false } // the common case: stay out of the way
            let (dx, dy) = ballDelta(of: event)
            let reaction = machine.move(dx: dx, dy: dy, at: time(of: event))
            if reaction.swallow {
                pointer.hold()
                stats.moves += 1
            }
            apply(reaction.outputs, release: nil)
            return reaction.swallow

        case .rightMouseDown, .otherMouseDown, .leftMouseDown:
            let current = config.withLock { $0 }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            guard button == Int64(current.trigger.rawValue), current.active else {
                apply(machine.interrupt(), release: nil)
                return false
            }
            machine.settings = current.settings
            heldPress = event.copy()
            let reaction = machine.triggerDown(at: time(of: event))
            apply(reaction.outputs, release: nil, pressLocation: event.location)
            return reaction.swallow

        case .rightMouseUp, .otherMouseUp:
            let trigger = config.withLock { $0.trigger }
            guard event.getIntegerValueField(.mouseEventButtonNumber) == Int64(trigger.rawValue) else {
                return false
            }
            let reaction = machine.triggerUp(at: time(of: event))
            apply(reaction.outputs, release: event)
            return reaction.swallow

        case .scrollWheel:
            // A real wheel takes over from a glide.
            apply(machine.interrupt(), release: nil)
            return false

        default:
            return false
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        stats.frames += 1
        apply(machine.frame(at: link.timestamp), release: nil)
    }

    private func apply(_ outputs: [GestureMachine.Output], release: CGEvent?, pressLocation: CGPoint? = nil) {
        for output in outputs {
            switch output {
            case .freezePointer:
                pointer.freeze(at: pressLocation ?? CGEvent(source: nil)?.location ?? .zero)
            case .releasePointer:
                pointer.release()
            case .click:
                replayClick(release: release)
            case let .scroll(dx, dy, phase):
                postScroll(dx: dx, dy: dy, phase: phase)
                stats.record(dx: dx, dy: dy, phase: phase)
            }
        }
        setFramesRunning(machine.needsFrames)
        if machine.isIdle {
            heldPress = nil
            if debugLogging, stats.hasContent {
                FileHandle.standardError.write(Data((stats.summary + "\n").utf8))
            }
            stats = GestureStats()
        }
    }

    private func setFramesRunning(_ running: Bool) {
        if running, displayLink?.isPaused != false {
            // Starting a gesture: tick with the display the pointer is on, so the
            // frame rate matches what the user is looking at.
            let display = displayUnderPointer()
            if displayLink == nil || display != linkedDisplay {
                displayLink?.invalidate()
                displayLink = nil
                guard let screen = screen(for: display) ?? NSScreen.main ?? NSScreen.screens.first else { return }
                let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
                link.add(to: .current, forMode: .common)
                displayLink = link
                linkedDisplay = display
            }
        }
        if let displayLink, displayLink.isPaused == running {
            displayLink.isPaused = !running
        }
    }

    private func displayUnderPointer() -> CGDirectDisplayID {
        guard let point = CGEvent(source: nil)?.location else { return CGMainDisplayID() }
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &display, &count)
        return count > 0 ? display : CGMainDisplayID()
    }

    private func screen(for display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
    }

    // MARK: - Reading events

    /// Ball movement in device counts, before the system's pointer acceleration
    /// where that is available, so scrolling does not depend on pointer settings.
    private func ballDelta(of event: CGEvent) -> (Double, Double) {
        let rawX = event.getDoubleValueField(.eventUnacceleratedPointerMovementX)
        let rawY = event.getDoubleValueField(.eventUnacceleratedPointerMovementY)
        if rawX != 0 || rawY != 0 {
            stats.rawMoves += 1
            return (rawX, rawY)
        }
        return (
            Double(event.getIntegerValueField(.mouseEventDeltaX)),
            Double(event.getIntegerValueField(.mouseEventDeltaY))
        )
    }

    /// Event time in seconds on the same clock as `CACurrentMediaTime`.
    private func time(of event: CGEvent) -> Double {
        let now = CACurrentMediaTime()
        let stamp = Double(event.timestamp) / 1_000_000_000
        // Trust the event's own timestamp when it is plausible; it is immune to
        // delays in delivering the event to us.
        return abs(now - stamp) < 0.2 ? min(stamp, now) : now
    }

    // MARK: - Posting events

    private func postScroll(dx: Int, dy: Int, phase: GestureMachine.Phase) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: dy),
            wheel2: Int32(clamping: dx),
            wheel3: 0
        ) else { return }

        // The same phase values a trackpad sends, so apps treat this as one
        // continuous gesture followed by an optional glide.
        let scrollPhase: Int64
        let momentumPhase: Int64
        switch phase {
        case .began: (scrollPhase, momentumPhase) = (1, 0)
        case .changed: (scrollPhase, momentumPhase) = (2, 0)
        case .ended: (scrollPhase, momentumPhase) = (4, 0)
        case .momentumBegan: (scrollPhase, momentumPhase) = (0, 1)
        case .momentumChanged: (scrollPhase, momentumPhase) = (0, 2)
        case .momentumEnded: (scrollPhase, momentumPhase) = (0, 3)
        }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: scrollPhase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentumPhase)
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        // Carry the held modifier keys so Cmd-scroll, Shift-scroll and friends work.
        event.flags = CGEventSource.flagsState(.combinedSessionState)
        event.post(tap: .cgSessionEventTap)
    }

    /// The press was held back to see whether it would become a scroll. It did
    /// not, so deliver the click now, at the spot where the button went down.
    private func replayClick(release: CGEvent?) {
        guard let down = heldPress?.copy(), let up = release?.copy() else { return }
        up.location = down.location
        for event in [down, up] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
            event.post(tap: .cgSessionEventTap)
        }
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<ScrollEngine>.fromOpaque(userInfo).takeUnretainedValue()
    return engine.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
}

/// Holds the pointer in place while the ball is being used for scrolling.
///
/// macOS moves the pointer before any app sees the movement, and that cannot be
/// vetoed. So the pointer is put back after every movement. Normally the system
/// pauses pointer movement for a moment after such a jump; stretching that
/// pause is what makes the pointer look frozen instead of twitching.
final class PointerFreezer {
    private static let normalSuppression: CFTimeInterval = 0.25
    private static let frozenSuppression: CFTimeInterval = 10

    private let source = CGEventSource(stateID: .combinedSessionState)
    private var anchor: CGPoint?

    /// Undo a stretched pause left behind if the app was killed mid-scroll.
    func restoreSystemDefault() {
        source?.localEventsSuppressionInterval = Self.normalSuppression
    }

    func freeze(at point: CGPoint) {
        anchor = point
        source?.localEventsSuppressionInterval = Self.frozenSuppression
        CGWarpMouseCursorPosition(point)
    }

    func hold() {
        if let anchor { CGWarpMouseCursorPosition(anchor) }
    }

    func release() {
        guard let anchor else { return }
        // A jump made with no pause lets the pointer move again immediately.
        source?.localEventsSuppressionInterval = 0
        CGWarpMouseCursorPosition(anchor)
        source?.localEventsSuppressionInterval = Self.normalSuppression
        self.anchor = nil
    }
}

/// Numbers describing one gesture, printed with `--debug` to help tune the feel.
private struct GestureStats {
    var moves = 0
    var rawMoves = 0
    var frames = 0
    var scrollEvents = 0
    var glideEvents = 0
    var pixels = SIMD2<Int>(0, 0)
    var glidePixels = SIMD2<Int>(0, 0)

    var hasContent: Bool { moves > 0 }

    mutating func record(dx: Int, dy: Int, phase: GestureMachine.Phase) {
        switch phase {
        case .began, .changed, .ended:
            scrollEvents += 1
            pixels &+= SIMD2(dx, dy)
        case .momentumBegan, .momentumChanged, .momentumEnded:
            glideEvents += 1
            glidePixels &+= SIMD2(dx, dy)
        }
    }

    var summary: String {
        let kind = scrollEvents == 0 ? "click" : "scroll"
        return "[BallScroll] \(kind): \(moves) ball reports (\(rawMoves) unaccelerated), "
            + "\(frames) frames, \(scrollEvents) scroll events for (\(pixels.x), \(pixels.y)) px, "
            + "\(glideEvents) glide events for (\(glidePixels.x), \(glidePixels.y)) px"
    }
}
