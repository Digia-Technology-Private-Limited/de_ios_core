import Darwin
import UIKit

/// Delivers a real tap the way the touchscreen does: a digitizer `IOHIDEvent` (one finger down,
/// then up) handed to UIKit through `UIApplication._enqueueHIDEvent`, addressed to the window's
/// render context. UIKit builds the `UITouch`, hit-tests and dispatches it itself, exactly as for a
/// finger, so UIKit gesture recognizers *and* SwiftUI gestures (`Button`, `onTapGesture`) see it.
/// Building the `UITouch` by hand and calling `sendEvent` reaches UIKit recognizers but not
/// SwiftUI, which ignores such touches.
///
/// Needs a host app: without a `UIApplication` there is no event dispatcher. iOS has no public
/// touch-injection API, so this drives UIKit's, IOKit's and BackBoardServices' private one, as
/// lyft's Hammer does. Test target only.
@MainActor
enum TouchSynthesizer {

    struct Unavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// Taps `point`, in `window`'s coordinates, and drains the run loop so the tap's handler runs.
    static func tap(at point: CGPoint, in window: UIWindow) throws {
        // `UIApplication.shared` is declared non-optional but is nil without a host app; ask the
        // runtime so that case fails loudly instead of messaging nil.
        guard let application = (UIApplication.self as AnyObject)
            .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
        else {
            throw Unavailable(description: "No UIApplication: the test bundle needs a host app")
        }
        let hid = try HIDEvents()
        let contextID = try call(window, "_contextId") as UInt32
        // The digitizer reports screen points.
        let location = window.convert(point, to: nil)

        try enqueue(hid.handEvent(at: location, touching: true, contextID: contextID), into: application, hid: hid)
        // A finger stays down for a moment; a zero-length press is not what a recognizer sees.
        drainRunLoop(for: 0.05)
        try enqueue(hid.handEvent(at: location, touching: false, contextID: contextID), into: application, hid: hid)
        drainRunLoop(for: 0.15)
    }

    private static func enqueue(_ event: UnsafeMutableRawPointer, into application: UIApplication, hid: HIDEvents) throws {
        defer { hid.release(event) }
        typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Void
        let (fn, selector) = try method(application, "_enqueueHIDEvent:", as: Fn.self)
        fn(application, selector, event)
    }

    static func drainRunLoop(for seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
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
    private static let fieldBuiltIn: UInt32 = 4
    /// `kIOHIDEventFieldDigitizerIsDisplayIntegrated`: digitizer field base (type 11 << 16) + 25.
    private static let fieldDisplayIntegrated: UInt32 = (11 << 16) + 25
    private static let fieldOptions = UInt32(bitPattern: -268_435_456)
    /// The finger's identity; the same for the down and up events of one tap.
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

    /// A +1 hand event with one finger at `location` (screen points), down or lifting; balance it
    /// with `release`.
    func handEvent(at location: CGPoint, touching: Bool, contextID: UInt32) throws -> UnsafeMutableRawPointer {
        let time = mach_absolute_time()
        let down: UInt8 = touching ? 1 : 0
        // Range and touch both change on a tap's down and its up.
        let changed = Self.eventRange | Self.eventTouch
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
