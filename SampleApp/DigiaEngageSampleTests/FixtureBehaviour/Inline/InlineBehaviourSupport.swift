import AVFoundation
import Darwin
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

// Shared by the inline suites in this folder: the app page that holds a slot, where on it the
// slot was drawn, what the backend received about it, and the players its stories opened.

/// Where the slot was laid out, in window points. The story rail and the carousel have no
/// accessibility element per card or dot, so a test taps them by position inside this frame.
@MainActor
final class InlineSlotFrame {
    var frame: CGRect = .null
}

/// The app's page: the slot at the top of the screen, as a customer places a banner row.
struct InlineSlotPage: View {
    let slot: String
    let probe: InlineSlotFrame

    var body: some View {
        VStack(spacing: 0) {
            DigiaSlot(slot) { EmptyView() }
                .background {
                    GeometryReader { proxy in
                        let frame = proxy.frame(in: .global)
                        Color.clear
                            .onAppear { probe.frame = frame }
                            .onChange(of: frame) { probe.frame = $0 }
                    }
                }
            Spacer(minLength: 0)
        }
    }
}

/// One frame of a story as the backend received it: `item_index` of `item_total`.
struct InlineStoryFrame: Equatable, CustomStringConvertible {
    let index: Int
    let total: Int?

    init(_ index: Int, _ total: Int?) {
        self.index = index
        self.total = total
    }

    var description: String { "(\(index), \(total.map(String.init) ?? "nil"))" }
}

/// A video player the story rail or viewer put on screen, and where it was first seen playing.
@MainActor
final class InlineSeenPlayer {
    let player: AVPlayer
    /// Index of the rail card it sits on, or nil when it fills the screen (the viewer's).
    let card: Int?
    /// Playhead, in seconds, the first time it was seen playing; nil while it never played.
    var firstPlayingAt: Double?

    init(player: AVPlayer, card: Int?) {
        self.player = player
        self.card = card
    }
}

extension SdkHarness {

    /// Opens the app with [slot] at the top of its page and returns where it is drawn.
    func mountInlineSlot(_ slot: String) throws -> InlineSlotFrame {
        let probe = InlineSlotFrame()
        try mount { InlineSlotPage(slot: slot, probe: probe) }
        return probe
    }

    /// The tracked event properties of [campaignKey] named [name], in order.
    func inlineEvents(_ name: String, of campaignKey: String) async throws -> [[String: Any]] {
        try await events()
            .filter { $0["campaign_key"] as? String == campaignKey && $0["event_name"] as? String == name }
            .map { $0["properties"] as? [String: Any] ?? [:] }
    }

    /// Polls the backend until [count] events named [name] of [campaignKey] arrived, and returns
    /// them. Records an issue and throws when they do not arrive in time.
    func waitForEvents(_ name: String, of campaignKey: String, count: Int, timeout: TimeInterval = 4) async throws -> [[String: Any]] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let found = try await inlineEvents(name, of: campaignKey)
            if found.count >= count { return found }
            if Date() > deadline {
                Issue.record("Timed out waiting for \(count) \(name) of \(campaignKey); got \(found.count)")
                throw TimedOut()
            }
        }
    }

    /// Every story frame shown so far, as the backend received the `Digia Step Viewed` events.
    func storyFramesShown(_ campaignKey: String) async throws -> [InlineStoryFrame] {
        try await inlineEvents("Digia Step Viewed", of: campaignKey).map {
            InlineStoryFrame($0["item_index"] as? Int ?? -1, $0["item_total"] as? Int)
        }
    }

    /// Taps the [index]th card of a story rail drawn in [slot], with the rail's card geometry.
    func tapStoryCard(_ index: Int, in slot: InlineSlotFrame, card: StoryCardConfig) async throws {
        let window = try #require(window)
        try await waitUntil("the story rail is laid out") { !slot.frame.isNull && slot.frame.height > 1 }
        // Settle any layout pass the delivery started before measuring.
        TouchSynthesizer.drainRunLoop(for: 0.3)
        let width = CGFloat(card.width)
        let spacing = CGFloat(card.spacing)
        let x = slot.frame.minX + spacing + CGFloat(index) * (width + spacing) + width / 2
        try TouchSynthesizer.tap(at: CGPoint(x: x, y: slot.frame.midY), in: window)
    }

    /// A real touch on the story viewer's call-to-action button, once it reads [label].
    ///
    /// The viewer's page reads out as one accessibility node holding every label on it, so its
    /// controls have no frame of their own to tap; the touch goes where `InlineStoryOverlayContent`
    /// lays the button out: full width less 24 pt each side, 20 pt above the bottom safe area,
    /// 12 pt of padding around a 16 pt line.
    func tapStoryCTA(_ label: String) async throws {
        let window = try #require(window)
        try await waitUntil("the call to action \(label) is on screen") { self.isShowing(label) }
        let center = window.bounds.height - window.safeAreaInsets.bottom - 20 - 21
        try TouchSynthesizer.tap(at: CGPoint(x: window.bounds.midX, y: center), in: window)
    }

    /// A real touch on the story viewer's [position]th round button from the right (0 is the
    /// close button when it shows, the mute button sits left of it), once it reads [label]. As
    /// for `tapStoryCTA`, the touch goes where the viewer lays the buttons out: a row of 48 pt
    /// targets 8 pt apart, inset by the indicator's horizontal padding, 12 pt under the indicator.
    func tapStoryButton(_ label: String, position: Int, indicator: StoryIndicatorDisplayConfig) async throws {
        let window = try #require(window)
        try await waitUntil("the \(label) button is on screen") { self.isShowing(label) }
        let x = window.bounds.width - CGFloat(indicator.horizontalPadding) - 24 - CGFloat(position) * (48 + 8)
        let y = window.safeAreaInsets.top + CGFloat(indicator.topPadding + indicator.height) + 12 + 24
        try TouchSynthesizer.tap(at: CGPoint(x: x, y: y), in: window)
    }

    /// Whether the full-screen story viewer is up: the SDK holds an open story and the viewer is
    /// presented over the app.
    var storyViewerIsOpen: Bool {
        sdk.controller.activeStoryOverlay != nil && presentedViewer != nil
    }

    /// Waits for the story viewer to be presented and its cross-dissolve to finish, so a touch
    /// reaches it rather than the page under it.
    func waitForStoryViewer() async throws {
        try await waitUntil("the story viewer is presented") { self.storyViewerIsOpen }
        try await waitUntil("the story viewer is in place") {
            guard let presented = self.presentedViewer else { return false }
            return !presented.isBeingPresented && presented.view.window != nil
        }
        TouchSynthesizer.drainRunLoop(for: 0.4)
    }

    /// Waits for the story viewer to be gone, from the SDK and from the screen.
    func waitForStoryViewerClosed(timeout: TimeInterval = 3) async throws {
        try await waitUntil("the story viewer is closed", timeout: timeout) {
            self.sdk.controller.activeStoryOverlay == nil && self.presentedViewer == nil
        }
    }

    /// Closes the story viewer if it is up, waits for it to leave the screen, and sends what it
    /// reported on the way out. Call at the end of a test that opened it: a viewer torn down with
    /// the window reports its dismissal late, into the next test's backend.
    func closeStoryViewer() async throws {
        if sdk.controller.activeStoryOverlay != nil { sdk.controller.dismissStoryOverlay() }
        try await waitForStoryViewerClosed()
        TouchSynthesizer.drainRunLoop(for: 0.3)
        _ = try await events()
    }

    /// A real tap on the story viewer: [fraction] of the way across the screen, at its middle.
    func tapStoryViewer(atFraction fraction: CGFloat) throws {
        let window = try #require(window)
        let point = CGPoint(x: window.bounds.width * fraction, y: window.bounds.midY)
        try TouchSynthesizer.tap(at: point, in: window)
    }

    /// The video players on screen now: each `InlineStoryPlayerContainer` holding a player, with
    /// the rail card it sits on (by its frame inside [slot]).
    func storyPlayers(in slot: InlineSlotFrame, card: StoryCardConfig) -> [(card: Int?, player: AVPlayer)] {
        guard let window else { return [] }
        var found: [(Int?, AVPlayer)] = []
        func walk(_ view: UIView) {
            if let container = view as? InlineStoryPlayerContainer, let player = container.playerLayer.player {
                let frame = container.convert(container.bounds, to: window)
                let stride = CGFloat(card.width + Double(card.spacing))
                let index = frame.width < window.bounds.width * 0.9
                    ? Int(((frame.midX - slot.frame.minX - CGFloat(card.spacing)) / stride).rounded(.down))
                    : nil
                found.append((index, player))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(window)
        return found
    }
}

/// Watches the story players for as long as a test runs, keeping every player it saw in the order
/// it first saw each, with where its playhead was when it started playing.
///
/// Players are held strongly: an `ObjectIdentifier` of a released player could otherwise be
/// reused by the next one.
@MainActor
final class InlinePlayerWatch {
    private(set) var seen: [InlineSeenPlayer] = []
    private var task: Task<Void, Never>?

    init(_ sdk: SdkHarness, slot: InlineSlotFrame, card: StoryCardConfig) {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.sample(sdk.storyPlayers(in: slot, card: card))
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    deinit { task?.cancel() }

    func stop() { task?.cancel() }

    private func sample(_ players: [(card: Int?, player: AVPlayer)]) {
        for (card, player) in players {
            let entry: InlineSeenPlayer
            if let known = seen.first(where: { $0.player === player }) {
                entry = known
            } else {
                entry = InlineSeenPlayer(player: player, card: card)
                seen.append(entry)
            }
            if entry.firstPlayingAt == nil, player.rate > 0 {
                entry.firstPlayingAt = player.currentTime().seconds
            }
        }
    }

    /// The players that have started playing, in order.
    var played: [InlineSeenPlayer] { seen.filter { $0.firstPlayingAt != nil } }

    /// The [count]th player to start playing, once it has.
    func playing(_ count: Int) -> InlineSeenPlayer? {
        let played = played
        return played.count >= count ? played[count - 1] : nil
    }

    /// Each player that played, as "card <n> from <s>s": the card it sits on and where it started,
    /// read as 0 s when it began within half a second of the start and as 2 s when it began
    /// between 1.9 s and 2.6 s (anything else reads -1 s).
    var starts: [String] {
        played.map { entry in
            let start = entry.firstPlayingAt ?? -1
            let whole = start < 0.5 ? 0 : (start >= 1.9 && start < 2.6 ? 2 : -1)
            return "card \(entry.card.map(String.init) ?? "full") from \(whole)s"
        }
    }
}

/// Moves a player's playhead to just before the end of its video, so it runs out the way it would
/// after playing through (the Flutter tests move the fake player's playhead the same way).
@MainActor
func inlineRunOut(_ player: AVPlayer) async {
    guard let duration = player.currentItem?.duration, duration.isNumeric else { return }
    let target = CMTimeSubtract(duration, CMTime(value: 150, timescale: 1_000))
    await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
}

/// A server clock that stands still: `TrustedTimeAnchor.nowMs()` counts time from its monotonic
/// instant, clamped at zero, so an anchor whose instant lies an hour ahead reads [epochMs] for
/// that hour. The Flutter timer tests read the countdown off a fake clock the same way.
func inlineFrozenClock(at date: Date) -> TrustedTimeAnchor {
    TrustedTimeAnchor(
        serverEpochMs: Int64((date.timeIntervalSince1970 * 1000).rounded()),
        continuousNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) + 3_600 * 1_000_000_000
    )
}

func inlineUTC(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

/// The app going to the background and coming back, as UIKit announces it to the SDK.
@MainActor
enum InlineAppLifecycle {
    static func resignActive() {
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: UIApplication.shared)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }

    static func becomeActive() {
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: UIApplication.shared)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }
}

/// A real one-finger drag or press, delivered as the touchscreen delivers it: a digitizer down, a
/// run of moves and an up, each an `IOHIDEvent` handed to UIKit through
/// `UIApplication._enqueueHIDEvent`. `TouchSynthesizer` keeps its event builder private and only
/// taps, so the inline suites carry this copy of it with the moved phase a drag needs.
@MainActor
enum InlineTouch {

    /// Drags from [start] by [translation] (window points) over [duration], then lifts.
    static func drag(from start: CGPoint, by translation: CGVector, in window: UIWindow, duration: TimeInterval = 0.15, steps: Int = 10) throws {
        let session = try Session(window: window)
        let origin = window.convert(start, to: nil)
        func point(_ fraction: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + translation.dx * fraction, y: origin.y + translation.dy * fraction)
        }
        try session.send(origin, .down)
        TouchSynthesizer.drainRunLoop(for: 0.02)
        for step in 1...steps {
            try session.send(point(CGFloat(step) / CGFloat(steps)), .moved)
            TouchSynthesizer.drainRunLoop(for: duration / Double(steps))
        }
        try session.send(point(1), .up)
        TouchSynthesizer.drainRunLoop(for: 0.15)
    }

    /// A finger held still at [point] for [seconds], then lifted.
    static func press(at point: CGPoint, in window: UIWindow, for seconds: TimeInterval, whileHeld: () -> Void = {}) throws {
        let session = try Session(window: window)
        let location = window.convert(point, to: nil)
        try session.send(location, .down)
        let ticks = max(1, Int(seconds / 0.05))
        for _ in 0..<ticks {
            TouchSynthesizer.drainRunLoop(for: seconds / Double(ticks))
            try session.send(location, .moved)
        }
        whileHeld()
        try session.send(location, .up)
        TouchSynthesizer.drainRunLoop(for: 0.1)
    }

    private struct Session {
        let application: UIApplication
        let hid: InlineHIDEvents
        let contextID: UInt32

        init(window: UIWindow) throws {
            guard let application = (UIApplication.self as AnyObject)
                .perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication
            else { throw TouchSynthesizer.Unavailable(description: "No UIApplication: the test bundle needs a host app") }
            self.application = application
            hid = try InlineHIDEvents()
            typealias ContextFn = @convention(c) (NSObject, Selector) -> UInt32
            let selector = NSSelectorFromString("_contextId")
            guard window.responds(to: selector) else { throw TouchSynthesizer.Unavailable(description: "UIWindow._contextId") }
            contextID = unsafeBitCast(window.method(for: selector), to: ContextFn.self)(window, selector)
        }

        func send(_ location: CGPoint, _ phase: InlineHIDEvents.Phase) throws {
            let event = try hid.handEvent(at: location, phase: phase, contextID: contextID)
            defer { hid.release(event) }
            typealias Fn = @convention(c) (NSObject, Selector, UnsafeMutableRawPointer) -> Void
            let selector = NSSelectorFromString("_enqueueHIDEvent:")
            guard application.responds(to: selector) else {
                throw TouchSynthesizer.Unavailable(description: "UIApplication._enqueueHIDEvent:")
            }
            unsafeBitCast(application.method(for: selector), to: Fn.self)(application, selector, event)
        }
    }
}

/// IOKit digitizer events, as in `TouchSynthesizer`'s, plus the moved phase a drag needs.
private struct InlineHIDEvents {
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
