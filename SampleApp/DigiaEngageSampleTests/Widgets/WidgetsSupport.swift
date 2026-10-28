import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// The debug switches live in `SDKInstance.shared`'s services, which outlive `resetForTesting()`:
/// the in-memory flag a test flips is still set for the next suite, and a bubble left on would sit
/// over every other suite's screen. Every widgets suite puts them back before and after itself.
@MainActor
enum WidgetsDebugState {
    static func reset() {
        let sdk = SDKInstance.shared
        sdk.setCaptureModeEnabled(false)
        sdk.setCaptureProfile(includeText: false, includeMedia: false, includeStructure: false)
        sdk.componentRegistrySnapshot().setEnabled(false)
        sdk.debugOverlayControllerSnapshot().setVisible(false)
        sdk.liveTestServiceSnapshot().setEnabled(false)
        sdk.liveTestServiceSnapshot().setDeviceName("")
    }

    /// What the SDK keeps on disk under [key] (`<domain>.<key>` in the SDK's suite).
    static func stored(_ key: String) -> Bool {
        UserDefaults(suiteName: SdkHarness.storageSuite)?.bool(forKey: key) ?? false
    }

    static func storedString(_ key: String) -> String? {
        UserDefaults(suiteName: SdkHarness.storageSuite)?.string(forKey: key)
    }
}

extension SdkHarness {

    /// Boots the SDK with no campaigns over a plain app, debug switches all off. With
    /// [reactNative] the SDK is configured as the React Native binding, the one binding that
    /// offers page capture.
    static func widgetsBoot(reactNative: Bool = false) async throws -> SdkHarness {
        let sdk = try SdkHarness.create()
        WidgetsDebugState.reset()
        try await Digia.initialize(DigiaConfig(
            apiKey: "test-api-key", wrapperBinding: reactNative ? "react_native" : nil))
        try await sdk.waitUntil("the SDK is ready", timeout: 10) { sdk.sdk.sdkState != .initializing }
        try sdk.requireReady()
        try sdk.mount { Text("host app") }
        return sdk
    }

    func widgetsFinish() {
        window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        TouchSynthesizer.drainRunLoop(for: 0.2)
        WidgetsDebugState.reset()
        tearDown()
    }

    /// The debug settings screen, if it is the screen presented over the app.
    var widgetsSettingsScreen: UIViewController? {
        presentedViewer as? UIHostingController<DigiaDebugSettingsView>
    }

    /// Opens the debug settings over the app as the host's debug menu would.
    func widgetsOpenSettings() async throws {
        let root = try #require(window?.rootViewController)
        Digia.presentDebugSettings(from: root)
        try await waitUntil("the debug settings are open") { self.widgetsSettingsScreen != nil }
        try await waitUntil("the debug settings are on screen") { self.isShowing("Digia bubble") }
    }

    func widgetsCloseSettings() async throws {
        window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        try await waitUntil("the debug settings are closed") { self.presentedViewer == nil }
        try await settle(0.3)
    }

    // MARK: - Reading the screen

    /// Every on-screen accessibility node that shows exactly [text].
    func widgetsFrames(exactly text: String) -> [CGRect] {
        widgetsFrames { Self.shownText(of: $0) == text }
    }

    func widgetsIsShowing(exactly text: String) -> Bool {
        !widgetsFrames(exactly: text).isEmpty
    }

    /// Frames, in window points, of every on-screen node matching [match].
    func widgetsFrames(where match: (NSObject) -> Bool) -> [CGRect] {
        guard let window else { return [] }
        var frames: [CGRect] = []
        Self.widgetsCollect(in: window, where: match) { object in
            let frame = window.convert(object.accessibilityFrame, from: window.screen.coordinateSpace).integral
            if !frame.isEmpty, !frames.contains(frame) { frames.append(frame) }
        }
        return frames
    }

    /// Frames of the row titled [title]: SwiftUI reads a row's title and subtitle out as one
    /// element, "Title, Subtitle".
    func widgetsRowFrames(_ title: String) -> [CGRect] {
        widgetsFrames { object in
            guard let text = Self.shownText(of: object) else { return false }
            return text == title || text.hasPrefix(title + ", ")
        }
    }

    /// The on/off switch on the row titled [title]: the switch level with the title, to its right.
    /// A SwiftUI `Toggle` reads out "0" or "1".
    func widgetsSwitchFrame(row title: String) -> CGRect? {
        let switches = widgetsFrames { $0.accessibilityValue == "0" || $0.accessibilityValue == "1" }
        for titleFrame in widgetsRowFrames(title) {
            let level = switches
                .filter { $0.minX > titleFrame.midX && abs($0.midY - titleFrame.midY) < 32 }
                .min { abs($0.midY - titleFrame.midY) < abs($1.midY - titleFrame.midY) }
            if let level { return level }
        }
        return nil
    }

    /// A real touch on the switch of the row titled [title], until [done] holds.
    func widgetsTapSwitch(row title: String, until done: @escaping () -> Bool) async throws {
        try await widgetsTap("the \(title) switch", until: done) { self.widgetsSwitchFrame(row: title) }
    }

    /// A real touch on the row titled [title] (its title text), until [done] holds.
    func widgetsTap(row title: String, until done: @escaping () -> Bool) async throws {
        try await widgetsTap("the \(title) row", until: done) { self.widgetsRowFrames(title).first }
    }

    /// A real touch on the title line of the row titled [title], at its leading edge: a plain
    /// button row is hit only on its own text, not on the gap beside a short subtitle.
    func widgetsTap(rowTitle title: String, until done: @escaping () -> Bool) async throws {
        try await widgetsTap("the title of the \(title) row", until: done) {
            self.widgetsRowFrames(title).first.map { row in
                CGRect(x: row.minX + 16, y: row.minY + 8, width: 24, height: 12)
            }
        }
    }

    /// A real touch on the text reading exactly [text], until [done] holds.
    func widgetsTap(exactly text: String, until done: @escaping () -> Bool) async throws {
        try await widgetsTap("\"\(text)\"", until: done) { self.widgetsFrames(exactly: text).first }
    }

    /// Taps the centre of [frame] once it has stopped moving, and waits for [done]. A screen that
    /// has just been presented or pushed lists its elements at their final frame a moment before it
    /// takes touches, and a touch then is dropped, so an unanswered touch is sent again (at most
    /// three times). Only a touch that did nothing is repeated: [done] is what it should have done.
    func widgetsTap(
        _ what: String, until done: @escaping () -> Bool, at frame: @escaping () -> CGRect?
    ) async throws {
        let window = try #require(window)
        for _ in 0..<3 {
            let target = try await widgetsSteadyFrame(what, frame)
            try TouchSynthesizer.tap(at: CGPoint(x: target.midX, y: target.midY), in: window)
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if done() { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        if !done() { print("WIDGETS-DUMP after tapping \(what):\n\(widgetsDump())") }
        try await waitUntil("a tap on \(what) to take effect", timeout: 0.1, done)
    }

    /// Waits for [frame] to hold for 8 reads (400 ms): a pushed or presented screen lists its
    /// elements at their final frame before it takes touches.
    func widgetsSteadyFrame(_ what: String, _ frame: @escaping () -> CGRect?) async throws -> CGRect {
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("\(what) settled on screen", timeout: 8) {
            guard let current = frame() else { steadyReads = 0; last = nil; return false }
            steadyReads = current == last ? steadyReads + 1 : 0
            last = current
            return steadyReads >= 8
        }
        return try #require(last)
    }

    /// Every text and value on screen, for a failure message.
    func widgetsDump() -> String {
        guard let window else { return "" }
        var lines: [String] = []
        Self.widgetsCollect(in: window, where: { Self.shownText(of: $0) != nil || $0.accessibilityValue != nil }) {
            lines.append("\(Swift.type(of: $0)) text=\(Self.shownText(of: $0) ?? "-") value=\($0.accessibilityValue ?? "-") frame=\($0.accessibilityFrame)")
        }
        return lines.joined(separator: "\n")
    }

    static func widgetsCollect(
        in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool, into found: (NSObject) -> Void
    ) {
        guard depth < 60 else { return }
        if let view = root as? UIView, view.isHidden || view.alpha <= 0.01 { return }
        if match(root) { found(root) }
        if let view = root as? UIView {
            for subview in view.subviews { widgetsCollect(in: subview, depth: depth + 1, where: match, into: found) }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                widgetsCollect(in: element, depth: depth + 1, where: match, into: found)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject {
                        widgetsCollect(in: element, depth: depth + 1, where: match, into: found)
                    }
                }
            }
        }
    }
}

/// The live-test stream as `URLSessionNetworkClient` delivers it, over the harness's mock for
/// everything else. The shared `MockNetworkClient` answers a `cancel()` with `onClosed()`, which
/// production never does ("none after a caller's `cancel()`"), and that extra callback re-enters
/// `LiveTestSSEClient`'s disconnect handling: the error state a screen should show lasts a few
/// microseconds there. This stream sends at most one terminal callback and nothing after cancel.
final class WidgetsLiveStreamNetwork: NetworkClient, @unchecked Sendable {
    private let base: MockNetworkClient
    private let lock = NSLock()
    private var streams: [(handler: any SseStreamHandler, subscription: Subscription)] = []
    private var _opened: [NetworkRequest] = []

    init(base: MockNetworkClient) { self.base = base }

    /// Installs it as the SDK's network for the rest of the test.
    @MainActor
    static func install(over harness: SdkHarness) throws -> WidgetsLiveStreamNetwork {
        let network = WidgetsLiveStreamNetwork(base: harness.network)
        let client = try #require(SDKInstance.shared.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = network
        return network
    }

    /// Every stream the SDK opened, in order.
    var opened: [NetworkRequest] { lock.withLock { _opened } }

    /// What the dashboard sends down every open stream.
    func emit(_ event: SseEvent) {
        let live = lock.withLock { streams.filter { !$0.subscription.isCancelled }.map(\.handler) }
        for handler in live { handler.onEvent(event) }
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        try await base.execute(request: request)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        try await base.executeMultipart(request: request)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        let subscription = Subscription()
        lock.withLock {
            _opened.append(request)
            streams.append((handler, subscription))
        }
        handler.onOpen()
        return subscription
    }

    final class Subscription: CancellableSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
}
