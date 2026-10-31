import Darwin
import UIKit

/// Delivers real touches the way the touchscreen does: digitizer `IOHIDEvent`s (one finger down,
/// any moves, then up) handed to UIKit through `UIApplication._enqueueHIDEvent`, addressed to the
/// window's render context. UIKit builds the `UITouch`es, hit-tests and dispatches them itself,
/// exactly as for a finger, so UIKit gesture recognizers *and* SwiftUI gestures (`Button`,
/// `onTapGesture`, `DragGesture`) see them, and a pan recognizer measures the translation and the
/// release velocity it would measure for a finger. Building the `UITouch` by hand and calling
/// `sendEvent` reaches UIKit recognizers but not SwiftUI, which ignores such touches.
///
/// Needs a host app: without a `UIApplication` there is no event dispatcher. iOS has no public
/// touch-injection API, so this drives UIKit's, IOKit's and BackBoardServices' private one, as
/// lyft's Hammer does. Test target only; every real touch in this target goes through here.
@MainActor
enum TouchSynthesizer {

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Taps `point`, in `window`'s coordinates, and drains the run loop so the tap's handler runs.
    static func tap(at point: CGPoint, in window: UIWindow) throws {
        let session = try Session(window: window)
        // The digitizer reports screen points.
        let location = window.convert(point, to: nil)

        try session.send(location, .down)
        // A finger stays down for a moment; a zero-length press is not what a recognizer sees.
        drainRunLoop(for: 0.05)
        try session.send(location, .up)
        drainRunLoop(for: 0.15)
    }

    /// Drags from `start` by `translation` (window points) over `duration`, in `steps` moves, then
    /// holds still for `hold` before lifting. A long hold releases at rest (no fling); a short
    /// duration with no hold releases at speed. `pauseAfterDown` is how long the finger rests
    /// before it starts to move.
    static func drag(
        from start: CGPoint,
        by translation: CGVector,
        in window: UIWindow,
        duration: TimeInterval,
        steps: Int = 12,
        hold: TimeInterval = 0,
        pauseAfterDown: TimeInterval = 0.03
    ) throws {
        let session = try Session(window: window)
        let origin = window.convert(start, to: nil)
        func point(_ fraction: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + translation.dx * fraction, y: origin.y + translation.dy * fraction)
        }

        try session.send(origin, .down)
        drainRunLoop(for: pauseAfterDown)
        for step in 1...steps {
            try session.send(point(CGFloat(step) / CGFloat(steps)), .moved)
            drainRunLoop(for: duration / Double(steps))
        }
        if hold > 0 {
            // Still down, not moving: the recognizer's velocity decays to zero.
            let end = point(1)
            let ticks = max(1, Int(hold / 0.03))
            for _ in 0..<ticks {
                try session.send(end, .moved)
                drainRunLoop(for: hold / Double(ticks))
            }
        }
        try session.send(point(1), .up)
        drainRunLoop(for: 0.15)
    }

    /// A finger held still at `point` for `seconds`, then lifted.
    static func press(at point: CGPoint, in window: UIWindow, for seconds: TimeInterval, whileHeld: () -> Void = {}) throws {
        let session = try Session(window: window)
        let location = window.convert(point, to: nil)
        try session.send(location, .down)
        let ticks = max(1, Int(seconds / 0.05))
        for _ in 0..<ticks {
            drainRunLoop(for: seconds / Double(ticks))
            try session.send(location, .moved)
        }
        whileHeld()
        try session.send(location, .up)
        drainRunLoop(for: 0.1)
    }

    /// One finger on the touchscreen that a test moves and lifts itself: down at init, any number
    /// of moves, up at `release`, so a test can look at the screen mid-drag.
    @MainActor
    final class Finger {
        private let window: UIWindow
        private let session: Session
        private(set) var location: CGPoint

        init(window: UIWindow, start: CGPoint) throws {
            self.window = window
            session = try Session(window: window)
            location = start
            try session.send(window.convert(start, to: nil), .down)
            TouchSynthesizer.drainRunLoop(for: 0.05)
        }

        /// Moves the finger to `point` (window coordinates) and lets a frame pass.
        func move(to point: CGPoint) throws {
            location = point
            try session.send(window.convert(point, to: nil), .moved)
            TouchSynthesizer.drainRunLoop(for: 0.016)
        }

        /// Lifts the finger where it is and lets the release's handlers run.
        func release() throws {
            try session.send(window.convert(location, to: nil), .up)
            TouchSynthesizer.drainRunLoop(for: 0.15)
        }
    }

    static func drainRunLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// The application, the window's render context and the event builder one gesture uses.
    @MainActor
    private struct Session {
        let application: UIApplication
        let hid: HIDEvents
        let contextID: UInt32

        init(window: UIWindow) throws {
            // `UIApplication.shared` is declared non-optional but is nil without a host app; ask the
            // runtime so that case fails loudly instead of messaging nil.
            guard let application = (UIApplication.self as AnyObject)
                .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
            else {
                throw Unavailable(description: "No UIApplication: the test bundle needs a host app")
            }
            self.application = application
            hid = try HIDEvents()
            contextID = try TouchSynthesizer.call(window, "_contextId") as UInt32
        }

        /// Sends one event at `location`, in screen points.
        func send(_ location: CGPoint, _ phase: HIDEvents.Phase) throws {
            let event = try hid.handEvent(at: location, phase: phase, contextID: contextID)
            defer { hid.release(event) }
            typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Void
            let (fn, selector) = try TouchSynthesizer.method(application, "_enqueueHIDEvent:", as: Fn.self)
            fn(application, selector, event)
        }
    }

    private static func method<T>(_ target: NSObject, _ name: String, as _: T.Type) throws -> (T, Selector) {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else {
            throw Unavailable(description: "\(type(of: target)).\(name)")
        }
        return (unsafeBitCast(target.method(for: selector), to: T.self), selector)
    }

    private static func call(_ target: NSObject, _ name: String) throws -> UInt32 {
        typealias Fn = @convention(c) (NSObject, Selector) -> UInt32
        let (fn, selector) = try method(target, name, as: Fn.self)
        return fn(target, selector)
    }
}

/// IOKit's digitizer events — a hand event holding one finger, which is what the touchscreen
/// driver produces for a single-finger touch — tagged by BackBoardServices with the window context
/// they are for.
private struct HIDEvents {
    /// Down and up change the finger's range and touch; a move changes only its position, the
    /// finger staying in range and touching.
    enum Phase { case down, moved, up }

    private typealias CreateDigitizerEvent = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias CreateFingerEvent = @convention(c) (
        UnsafeRawPointer?, UInt64, UInt32, UInt32, UInt32,
        Double, Double, Double, Double, Double, Double, Double, Double, Double, Double,
        UInt8, UInt8, UInt32
    ) -> UnsafeMutableRawPointer?
    private typealias SetIntegerValue = @convention(c) (UnsafeMutableRawPointer, UInt32, Int, UInt32) -> Void
    private typealias SetSenderID = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Void
    private typealias AppendEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32) -> Void
    private typealias SetDigitizerInfo = @convention(c) (
        UnsafeMutableRawPointer, UInt32, UInt8, UInt8, UnsafeRawPointer?, Double, Float
    ) -> Void
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> Void

    // IOHIDEventTypes.h / IOHIDDigitizer constants.
    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 1
    private static let eventTouch: UInt32 = 2
    private static let eventPosition: UInt32 = 4
    private static let fieldBuiltIn: UInt32 = 4
    /// `kIOHIDEventFieldDigitizerIsDisplayIntegrated`: digitizer field base (type 11 << 16) + 25.
    private static let fieldDisplayIntegrated: UInt32 = (11 << 16) + 25
    private static let fieldOptions = UInt32(bitPattern: -268_435_456)
    /// The finger's identity; the same for every event of one gesture.
    private static let fingerIdentity: UInt32 = 2

    private let createDigitizerEvent: CreateDigitizerEvent
    private let createFingerEvent: CreateFingerEvent
    private let setIntegerValue: SetIntegerValue
    private let setSenderID: SetSenderID
    private let appendEvent: AppendEvent
    private let setDigitizerInfo: SetDigitizerInfo
    private let cfRelease: Release

    init() throws {
        let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        let backboard = dlopen(
            "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW)
        func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw TouchSynthesizer.Unavailable(description: name)
            }
            return unsafeBitCast(pointer, to: T.self)
        }
        createDigitizerEvent = try symbol(iokit, "IOHIDEventCreateDigitizerEvent", as: CreateDigitizerEvent.self)
        createFingerEvent = try symbol(
            iokit, "IOHIDEventCreateDigitizerFingerEventWithQuality", as: CreateFingerEvent.self)
        setIntegerValue = try symbol(iokit, "IOHIDEventSetIntegerValueWithOptions", as: SetIntegerValue.self)
        setSenderID = try symbol(iokit, "IOHIDEventSetSenderID", as: SetSenderID.self)
        appendEvent = try symbol(iokit, "IOHIDEventAppendEvent", as: AppendEvent.self)
        setDigitizerInfo = try symbol(backboard, "BKSHIDEventSetDigitizerInfo", as: SetDigitizerInfo.self)
        cfRelease = try symbol(iokit, "CFRelease", as: Release.self)
    }

    /// A +1 hand event with one finger at `location` (screen points); balance it with `release`.
    func handEvent(at location: CGPoint, phase: Phase, contextID: UInt32) throws -> UnsafeMutableRawPointer {
        let time = mach_absolute_time()
        let down: UInt8 = phase == .up ? 0 : 1
        let changed = phase == .moved ? Self.eventPosition : (Self.eventRange | Self.eventTouch)
        guard
            let hand = createDigitizerEvent(
                nil, time, Self.transducerHand, 0, 0, changed, 0, 0, 0, 0, 0, 0, down, down, 0)
        else { throw TouchSynthesizer.Unavailable(description: "IOHIDEventCreateDigitizerEvent returned nil") }
        setIntegerValue(hand, Self.fieldDisplayIntegrated, 1, Self.fieldOptions)
        setIntegerValue(hand, Self.fieldBuiltIn, 1, Self.fieldOptions)
        setSenderID(hand, 0x0000_0001_2345_6789)

        guard
            let finger = createFingerEvent(
                nil, time, 1, Self.fingerIdentity, changed,
                Double(location.x), Double(location.y), 0, 0, 0, 5, 5, 1, 1, 1,
                down, down, 0)
        else {
            cfRelease(hand)
            throw TouchSynthesizer.Unavailable(
                description: "IOHIDEventCreateDigitizerFingerEventWithQuality returned nil")
        }
        setIntegerValue(finger, Self.fieldDisplayIntegrated, 1, Self.fieldOptions)
        appendEvent(hand, finger, 0)
        cfRelease(finger)
        // Address the event to the window's render context, as the system does for a finger.
        setDigitizerInfo(hand, contextID, 0, 0, nil, 0, 0)
        return hand
    }

    func release(_ event: UnsafeMutableRawPointer) {
        cfRelease(event)
    }
}
