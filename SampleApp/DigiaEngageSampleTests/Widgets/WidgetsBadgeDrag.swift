import Darwin
import UIKit

/// A real one-finger drag, delivered the way the touchscreen delivers it: a digitizer down, a run
/// of moves and an up, each an `IOHIDEvent` handed to UIKit through
/// `UIApplication._enqueueHIDEvent`. UIKit builds the `UITouch`es itself, so a drag
/// recognizer measures the translation *and* the release velocity it would measure
/// for a finger. Used to drag the debug bubble, which snaps to the nearer edge on release.
///
/// `TouchSynthesizer` (the shared tap) keeps its event builder private and only taps, so the
/// widgets suites carry this drag-capable copy of it (as the floater suites carry theirs, in a
/// folder of their own). Same private IOKit/BackBoardServices calls.
@MainActor
enum WidgetsBadgeDrag {

    /// Drags from `start` by `translation` (window points) over `duration`, in `steps` moves, then
    /// holds still for `hold` before lifting. A long hold releases at rest (no fling); a short
    /// duration with no hold releases at speed.
    static func drag(
        from start: CGPoint,
        by translation: CGVector,
        in window: UIWindow,
        duration: TimeInterval,
        steps: Int = 12,
        hold: TimeInterval = 0
    ) throws {
        let application = try sharedApplication()
        let hid = try WidgetsBadgeHIDEvents()
        let contextID = try contextId(of: window)
        let origin = window.convert(start, to: nil)
        func point(_ fraction: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + translation.dx * fraction, y: origin.y + translation.dy * fraction)
        }

        try enqueue(hid.handEvent(at: origin, phase: .down, contextID: contextID), into: application, hid: hid)
        TouchSynthesizer.drainRunLoop(for: 0.03)
        for step in 1...steps {
            try enqueue(
                hid.handEvent(at: point(CGFloat(step) / CGFloat(steps)), phase: .moved, contextID: contextID),
                into: application, hid: hid)
            TouchSynthesizer.drainRunLoop(for: duration / Double(steps))
        }
        if hold > 0 {
            // Still down, not moving: the recognizer's velocity decays to zero.
            let end = point(1)
            let ticks = max(1, Int(hold / 0.03))
            for _ in 0..<ticks {
                try enqueue(hid.handEvent(at: end, phase: .moved, contextID: contextID), into: application, hid: hid)
                TouchSynthesizer.drainRunLoop(for: hold / Double(ticks))
            }
        }
        try enqueue(hid.handEvent(at: point(1), phase: .up, contextID: contextID), into: application, hid: hid)
        TouchSynthesizer.drainRunLoop(for: 0.15)
    }

    private static func sharedApplication() throws -> UIApplication {
        guard let application = (UIApplication.self as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
        else { throw TouchSynthesizer.Unavailable(description: "No UIApplication: the test bundle needs a host app") }
        return application
    }

    private static func contextId(of window: UIWindow) throws -> UInt32 {
        typealias Fn = @convention(c) (NSObject, Selector) -> UInt32
        let selector = NSSelectorFromString("_contextId")
        guard window.responds(to: selector) else {
            throw TouchSynthesizer.Unavailable(description: "UIWindow._contextId")
        }
        return unsafeBitCast(window.method(for: selector), to: Fn.self)(window, selector)
    }

    private static func enqueue(
        _ event: UnsafeMutableRawPointer, into application: UIApplication, hid: WidgetsBadgeHIDEvents
    ) throws {
        defer { hid.release(event) }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Void
        let selector = NSSelectorFromString("_enqueueHIDEvent:")
        guard application.responds(to: selector) else {
            throw TouchSynthesizer.Unavailable(description: "UIApplication._enqueueHIDEvent:")
        }
        unsafeBitCast(application.method(for: selector), to: Fn.self)(application, selector, event)
    }
}

/// IOKit digitizer events, as in `TouchSynthesizer`'s, plus the moved phase a drag needs.
private struct WidgetsBadgeHIDEvents {
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

    private static let transducerHand: UInt32 = 3
    private static let eventRange: UInt32 = 1
    private static let eventTouch: UInt32 = 2
    private static let eventPosition: UInt32 = 4
    private static let fieldBuiltIn: UInt32 = 4
    private static let fieldDisplayIntegrated: UInt32 = (11 << 16) + 25
    private static let fieldOptions = UInt32(bitPattern: -268_435_456)
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
            guard let pointer = dlsym(handle, name) else { throw TouchSynthesizer.Unavailable(description: name) }
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
            throw TouchSynthesizer.Unavailable(description: "IOHIDEventCreateDigitizerFingerEventWithQuality returned nil")
        }
        setIntegerValue(finger, Self.fieldDisplayIntegrated, 1, Self.fieldOptions)
        appendEvent(hand, finger, 0)
        cfRelease(finger)
        setDigitizerInfo(hand, contextID, 0, 0, nil, 0, 0)
        return hand
    }

    func release(_ event: UnsafeMutableRawPointer) {
        cfRelease(event)
    }
}
