import Foundation
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Drives the real `SDKInstance.shared` over a scripted backend; the one harness for every suite
/// that needs a running SDK. Mirrors `flutter/core/test/support/sdk_harness.dart`.
///
/// The campaign comes from the (mocked) server through the real `Digia.initialize`, a CEP plugin
/// delivers it, the app's own `DigiaHost` renders it, and the test acts on what is on screen. Only
/// the boundaries outside the SDK are faked — the network (`MockNetworkClient` behind
/// `URLSessionNetworkClient.overrideForTesting`) and the OS (`ActionPlatform.current`, recorded by
/// `RecordingPlatform`) — so what a test asserts is what the user would see or what the SDK asked
/// iOS to do.
///
/// Compiled into both test targets: the package's `DigiaEngageTests` (no host app, so
/// ``activate(id:)`` reaches a control through accessibility) and the sample-app-hosted
/// `DigiaEngageSampleTests`, which adds real touches (`tap(id:)`) on top.
@MainActor
final class SdkHarness {

    /// The `actions/action_*` inline cards (all but the story and surface-specific ones) and
    /// `canvas_button_fill` share this slot and button; only the steps the button runs differ.
    static let buttonSlotKey = "home_banner"
    static let buttonId = "canvas_btn_primary"
    static let buttonLabel = "Confirm & Claim"

    /// The `UserDefaults` suite `SDKInstance.shared` keeps its storage in.
    static let storageSuite = "tech.digia.engage"

    /// The window ``mount(_:)`` lays the app out in, in points. Matches `_screen` in
    /// `flutter/core/test/support/sdk_harness.dart` and Android's `w390dp-h844dp`.
    static let screen = CGSize(width: 390, height: 844)

    let platform = RecordingPlatform()
    let network = MockNetworkClient()
    let plugin = FakeCep()
    /// The CEP plugin, under the name the held-boot suites use.
    var cep: FakeCep { plugin }
    var window: UIWindow!

    /// Set by the workspace-fixture boot (`CampaignBehaviour/Support/SdkHarness+Fixtures.swift`): the app is
    /// laid out full screen and the network is `StubBackend`, not `MockNetworkClient`.
    var servesWorkspaceFixtures = false
    /// Run last by ``tearDown()``: what a boot outside this file installed and must undo.
    var tearDownHooks: [() -> Void] = []

    /// Holds the bundle fetch for ``startHeld(_:actionHandlers:)``; nil for every other boot.
    private var heldNetwork: HeldBundleNetwork?
    /// `initialize`, left running by ``startHeld(_:actionHandlers:)`` until ``releaseBundle()``.
    private var initialization: Task<Void, Never>?

    /// What the scripted backend answers with. The network client calls it off the main actor.
    private let backend: ScriptedBackend

    /// Campaigns the campaign-bundle endpoint answers with.
    var campaigns: [[String: Any]] {
        get { backend.campaigns }
        set { backend.campaigns = newValue }
    }
    /// Status the campaign-bundle endpoint answers with.
    var bundleStatus: Int {
        get { backend.bundleStatus }
        set { backend.bundleStatus = newValue }
    }
    /// Headers the campaign-bundle endpoint answers with (e.g. the server clock).
    var bundleHeaders: [String: String] {
        get { backend.bundleHeaders }
        set { backend.bundleHeaders = newValue }
    }

    private let recorder = TimelineRecorder()
    /// Requests sent before `start` returned: earlier tests' queued events, not this test's.
    private var eventBaseline = 0

    init(campaigns: [[String: Any]]) {
        backend = ScriptedBackend(campaigns: campaigns)
    }

    var sdk: SDKInstance { SDKInstance.shared }

    // MARK: - Boot

    /// Resets the shared SDK over empty storage seeded with [stored] (raw values by full key, see
    /// ``frequencyState(_:total:windowCount:windowAnchorAt:stoppedAt:)``) and installs the fake
    /// backend and OS. Initialization is left to ``initialize(actionHandlers:)``.
    static func create(
        campaigns: [[String: Any]] = [],
        stored: [String: Any] = [:]
    ) throws -> SdkHarness {
        let harness = SdkHarness(campaigns: campaigns)
        let sdk = SDKInstance.shared
        sdk.resetForTesting()
        ComponentTestHost.enableAccessibilityAutomation()
        GoldenFonts.install()  // registers the TTFs; `initialize` then names the family via DigiaConfig

        let defaults = try #require(UserDefaults(suiteName: storageSuite))
        defaults.removePersistentDomain(forName: storageSuite)
        // Marks storage as already migrated, so no launch runs the migrator (and its cleanup of
        // the real caches directory).
        defaults.set(1, forKey: "storage.version")
        for (key, value) in stored { defaults.set(value, forKey: key) }

        harness.network.setResponseFactory { [backend = harness.backend] request in
            backend.answer(request)
        }
        let client = try #require(sdk.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = harness.network
        ActionPlatform.current = harness.platform.actionPlatform
        // The SDK keeps the last screen; a kept one would fire screen rules at ready.
        sdk.setCurrentScreen("")
        DigiaLogger.registerSink(harness.recorder)
        return harness
    }

    /// Boots the real SDK with [campaign] as the only campaign the server returns, with a CEP
    /// plugin attached.
    static func start(
        _ campaign: [String: Any],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        stored: [String: Any] = [:]
    ) async throws -> SdkHarness {
        try await start(campaigns: [campaign], actionHandlers: actionHandlers, stored: stored)
    }

    /// Boots the real SDK serving [campaigns], with a CEP plugin attached.
    static func start(
        campaigns: [[String: Any]],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        stored: [String: Any] = [:]
    ) async throws -> SdkHarness {
        let harness = try create(campaigns: campaigns, stored: stored)
        try await harness.initialize(actionHandlers: actionHandlers)
        // `initialize` stops waiting at its 2 s cap while the fetch carries on; on a loaded machine
        // the bundle can land after it.
        try await harness.waitUntil("the SDK is ready", timeout: 10) { harness.sdk.sdkState != .initializing }
        try harness.requireReady()
        try await harness.attachCep()
        // The analytics queue is on disk and outlives a test: send what earlier tests left in it
        // now, so `events()` reads only this test's.
        harness.sdk.services?.analyticsService?.flush()
        try await harness.settle(0.3)
        harness.eventBaseline = harness.network.recordedRequests.count
        return harness
    }

    /// As ``start(campaigns:actionHandlers:stored:)``, but registers the plugin before `initialize`
    /// and holds the bundle fetch. Returns while the SDK is still initializing;
    /// ``releaseBundle()`` lets it finish.
    static func startHeld(
        _ campaigns: [String: Any]...,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> SdkHarness {
        let harness = try create(campaigns: campaigns)
        let held = HeldBundleNetwork(harness.network)
        held.hold()
        harness.heldNetwork = held
        let client = try #require(harness.sdk.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = held
        Digia.register(harness.plugin)
        harness.initialization = Task { try? await harness.initialize(actionHandlers: actionHandlers) }
        try await harness.waitUntil("the SDK is initializing with the plugin attached") {
            harness.sdk.sdkState == .initializing && harness.plugin.host != nil
        }
        return harness
    }

    /// Answers the held bundle fetch, then waits for READY and for the plugin to flush its buffer.
    func releaseBundle() async throws {
        heldNetwork?.release()
        try await waitUntil("the SDK is READY") { sdk.sdkState == .ready }
        try await waitUntil("the plugin flushed its buffer") { plugin.buffered == 0 }
        await initialization?.value
        initialization = nil
    }

    /// Runs `Digia.initialize`, which returns once the bundle fetch has settled the SDK state.
    func initialize(actionHandlers: DigiaActionHandlers = DigiaActionHandlers()) async throws {
        try await Digia.initialize(DigiaConfig(apiKey: "test-api-key", fontFamily: GoldenFonts.family, actionHandlers: actionHandlers))
    }

    func requireReady() throws {
        try #require(sdk.sdkState == .ready, "initialize did not reach ready: \(sdk.sdkState)")
    }

    /// Registers the CEP plugin and waits for the SDK to attach it.
    func attachCep() async throws {
        Digia.register(plugin)
        try await waitUntil("the plugin is attached") { self.plugin.host != nil }
    }

    // MARK: - The app

    /// Mounts the app the way the integration guide tells customers to: `DigiaHost` around the
    /// app's own content, in a key window (of the host app's scene when there is one).
    func mount<Content: View>(@ViewBuilder _ content: () -> Content) throws {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: .zero)
        }
        // The same logical screen as the Flutter and Android harnesses, whatever simulator runs.
        window.frame = CGRect(origin: .zero, size: Self.screen)
        let host = UIHostingController(rootView: DigiaHost(content: content))
        window.rootViewController = host
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.3)
        self.window = window
    }

    /// What the CEP does when its campaign fires. The handle reports how the showing ended.
    @discardableResult
    func deliver(_ campaignKey: String, variables: [String: String]? = nil) throws -> CampaignPresentation {
        let host = try #require(plugin.host, "No CEP plugin attached")
        return host.deliver(CEPTriggerPayload(
            cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:],
            variables: variables))
    }

    /// How the showing ended, or nil while it is still running. Never blocks.
    func outcome(of presentation: CampaignPresentation) -> PresentationOutcome? {
        presentation.outcome.settledValue
    }

    /// The host app reporting a screen, as `Digia.setCurrentScreen(name:)` does.
    func setCurrentScreen(_ name: String) {
        Digia.setCurrentScreen(name: name)
    }

    /// The app's own deep-link routing, as a customer registers it at runtime.
    func setDeepLinkHandler(_ handler: DeepLinkHandler?) {
        Digia.setDeepLinkHandler(handler)
    }

    /// The app's own handling of web URLs, as a customer registers it at runtime.
    func setOpenURLHandler(_ handler: OpenURLHandler?) {
        Digia.setOpenURLHandler(handler)
    }

    // MARK: - Reading the screen

    /// Whether [text] is on screen: in a visible text view or label (canvas text is a `UITextView`)
    /// or read out by an accessibility element.
    func isShowing(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0)?.contains(text) == true } != nil
    }

    /// The accessibility element of the canvas element authored with [id] (`TestView` sets it as
    /// the accessibility identifier in debug builds), if it is on screen.
    func element(id: String) -> NSObject? {
        guard let window else { return nil }
        return Self.find(in: window) { Self.identifier(of: $0) == id }
    }

    /// The element that shows [text], if it is on screen.
    func element(text: String) -> NSObject? {
        guard let window else { return nil }
        return Self.find(in: window) { Self.shownText(of: $0)?.contains(text) == true }
    }

    /// Activates the control authored with [id] through accessibility — what VoiceOver's double-tap
    /// does. `TestView` puts the id on a container, so this activates the button inside it. The
    /// package test bundle has no `UIApplication`, so a synthesized touch never becomes a gesture
    /// there; the sample-app-hosted target taps with real touches instead.
    func activate(id: String) async throws {
        try await activate("element \(id)") { Self.identifier(of: $0) == id }
    }

    /// As ``activate(id:)``, for the control that shows [text].
    func activate(text: String) async throws {
        try await activate("text \(text)") { Self.shownText(of: $0)?.contains(text) == true }
    }

    private func activate(_ what: String, where match: @escaping (NSObject) -> Bool) async throws {
        try await waitUntil("\(what) on screen") { self.window.flatMap { Self.find(in: $0, where: match) } != nil }
        let element = try #require(window.flatMap { Self.find(in: $0, where: match) })
        let button = Self.findButton(in: element) ?? element
        try #require(button.accessibilityActivate(), "\(what) did not activate")
        ComponentTestHost.drainRunLoop(for: 0.2)
    }

    /// The first node at or under [root] with the button trait.
    private static func findButton(in root: NSObject, depth: Int = 0) -> NSObject? {
        guard depth < 40 else { return nil }
        if root.accessibilityTraits.contains(.button) { return root }
        var children: [NSObject] = []
        if let view = root as? UIView { children += view.subviews }
        if let elements = root.accessibilityElements as? [NSObject] { children += elements }
        for child in Mirror(reflecting: root).children where child.label == "children" {
            children += (child.value as? [NSObject]) ?? []
        }
        for child in children {
            if let found = findButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// The view controller presented over the app (a full-screen viewer, a sheet), if any.
    var presentedViewer: UIViewController? {
        window?.rootViewController?.presentedViewController
    }

    // MARK: - What the SDK reported

    /// Every tracked event this test sent, in order, after flushing what is queued.
    func events() async throws -> [[String: Any]] {
        sdk.services?.analyticsService?.flush()
        try await Task.sleep(nanoseconds: 300_000_000)
        return network.recordedRequests.dropFirst(eventBaseline)
            .filter { $0.url.path.hasSuffix("/engage/sdk/track") }
            .flatMap { request -> [[String: Any]] in
                guard let body = request.body,
                      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let events = json["events"] as? [[String: Any]]
                else { return [] }
                return events
            }
    }

    /// The names of the tracked events of [campaignKey], in order.
    func eventNames(of campaignKey: String) async throws -> [String] {
        try await events()
            .filter { $0["campaign_key"] as? String == campaignKey }
            .compactMap { $0["event_name"] as? String }
    }

    /// Every diagnostic record the SDK emitted since this harness was created, in order.
    var records: [TimelineRecord] { recorder.records }

    /// Diagnostic records of [campaignKey] carrying [reason].
    func records(_ campaignKey: String, reason: any DiagnosticReason) -> [TimelineRecord] {
        records.filter { $0.campaignKey == campaignKey && $0.reason?.wire == reason.wire }
    }

    /// The stored value the SDK keeps a campaign's frequency state under, as an earlier run left it.
    static func frequencyState(
        _ campaignKey: String,
        total: Int = 0,
        windowCount: Int = 0,
        windowAnchorAt: Int64? = nil,
        stoppedAt: Int64? = nil
    ) -> [String: Any] {
        var state: [String: Any] = ["total": total, "windowCount": windowCount]
        if let windowAnchorAt { state["windowAnchorAt"] = windowAnchorAt }
        if let stoppedAt { state["stoppedAt"] = stoppedAt }
        let raw = String(data: try! JSONSerialization.data(withJSONObject: state), encoding: .utf8)!
        return ["frequency.\(campaignKey)": raw]
    }

    /// Epoch milliseconds [seconds] before the wall clock: the frequency gate reads it, so a state
    /// "left by an earlier run" is anchored to it.
    static func msAgo(seconds: TimeInterval) -> Int64 {
        Int64((Date().timeIntervalSince1970 - seconds) * 1000)
    }

    // MARK: - Waiting

    func waitUntil(
        _ what: String, timeout: TimeInterval = 3, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                Issue.record("Timed out waiting for \(what)")
                throw TimedOut()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Lets main-actor work scheduled so far (a delivery's routing, a timer at zero) run.
    func settle(_ seconds: TimeInterval = 0.2) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    struct TimedOut: Error {}

    func tearDown() {
        heldNetwork?.release()
        initialization?.cancel()
        initialization = nil
        DigiaLogger.unregisterSink(recorder)
        if let window {
            if servesWorkspaceFixtures { window.isHidden = true } else { ComponentTestHost.cleanupOverlayWindow(window) }
        }
        window = nil
        SDKInstance.shared.floaterOrchestrator.dismiss(.hostTeardown)
        SDKInstance.shared.floaterStoryOrchestrator.dismiss(.hostTeardown)
        SDKInstance.shared.resetForTesting()
        for hook in tearDownHooks { hook() }
        tearDownHooks = []
    }

    // MARK: - Accessibility tree

    static func shownText(of object: NSObject) -> String? {
        (object as? UITextView)?.text ?? (object as? UILabel)?.text
            ?? object.accessibilityLabel ?? object.accessibilityValue
    }

    static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    static func find(in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool) -> NSObject? {
        guard depth < 60 else { return nil }
        if let view = root as? UIView {
            // Only what a user could see: hidden or transparent views and their subtrees don't count.
            guard !view.isHidden, view.alpha > 0.01 else { return nil }
        }
        if match(root) { return root }
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = find(in: subview, depth: depth + 1, where: match) { return found }
            }
        }
        if let elements = root.accessibilityElements {
            for case let element as NSObject in elements {
                if let found = find(in: element, depth: depth + 1, where: match) { return found }
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                for index in 0..<count {
                    if let element = root.accessibilityElement(at: index) as? NSObject,
                       let found = find(in: element, depth: depth + 1, where: match) {
                        return found
                    }
                }
            }
        }
        return nil
    }
}

extension CampaignPresentation {
    /// The drop reason, or nil while unsettled or when it was displayed.
    var dropReason: DropReason? {
        if case .dropped(let reason, _) = outcome.settledValue { return reason }
        return nil
    }

    /// The dismiss reason, once it displayed and then ended.
    var dismissReason: DismissReason? {
        if case .dismissed(let reason, _) = outcome.settledValue { return reason }
        return nil
    }
}

/// A CEP integration reduced to what it does in production: hold the host, hand it triggers, and
/// buffer what arrives before the host is ready.
@MainActor
final class FakeCep: DigiaCEPPlugin {
    let id = "action-test"
    private(set) var host: DigiaCEPHost?
    /// Every presentation ``receive(_:)`` delivered, in delivery order, with the campaign key.
    private(set) var presentations: [(campaignKey: String, presentation: CampaignPresentation)] = []
    private let buffer = PendingPayloadBuffer(onDrop: { _, _ in })

    /// How many payloads are waiting in the buffer.
    var buffered: Int { buffer.length }

    func attach(host: DigiaCEPHost) { self.host = host }

    func detach() {
        buffer.dropAll(.pluginDetached)
        host = nil
    }

    func onHostReady() {
        for trigger in buffer.takeAll() { deliver(trigger) }
    }

    /// What the CEP does when its campaign fires, with the runtime [variables] it supplies.
    @discardableResult
    func deliver(_ campaignKey: String, variables: [String: String]? = nil) -> CampaignPresentation? {
        deliver(CEPTriggerPayload(
            cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:],
            variables: variables))
    }

    /// What a real plugin does when its CEP calls back: delivers if the host is ready, otherwise
    /// buffers the payload. Returns the presentation when it delivered, nil when it buffered.
    @discardableResult
    func receive(_ campaignKey: String) -> CampaignPresentation? {
        let trigger = CEPTriggerPayload(
            cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:])
        guard let host, host.isReady else {
            buffer.add(trigger)
            return nil
        }
        return deliver(trigger)
    }

    @discardableResult
    private func deliver(_ trigger: CEPTriggerPayload) -> CampaignPresentation? {
        guard let host else { return nil }
        let presentation = host.deliver(trigger)
        presentations.append((trigger.campaignKey, presentation))
        return presentation
    }
}

/// The harness's network for ``SdkHarness/startHeld(_:actionHandlers:)``: forwards every request to
/// the `MockNetworkClient`, except that a bundle fetch waits while held, until `release()`.
private final class HeldBundleNetwork: NetworkClient, @unchecked Sendable {
    private let mock: MockNetworkClient
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ mock: MockNetworkClient) { self.mock = mock }

    func hold() { lock.withLock { held = true } }

    func release() {
        let pending = lock.withLock {
            held = false
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        if request.url.path.hasSuffix("/getCampaignBundle") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wait = lock.withLock {
                    if held { waiters.append(continuation) }
                    return held
                }
                if !wait { continuation.resume() }
            }
        }
        return try await mock.execute(request: request)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        try await mock.executeMultipart(request: request)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        mock.openSseStream(request: request, handler: handler)
    }
}

/// Stands in for iOS: records every call the SDK's actions make instead of leaving the app.
@MainActor
final class RecordingPlatform {
    private(set) var opened: [String] = []
    private(set) var copied: [String] = []
    private(set) var shared: [String] = []
    private(set) var reviewRequests = 0

    var actionPlatform: ActionPlatform {
        ActionPlatform(
            open: { [weak self] in self?.opened.append($0.absoluteString) },
            copy: { [weak self] in self?.copied.append($0) },
            share: { [weak self] in self?.shared.append($0) },
            requestReview: { [weak self] in self?.reviewRequests += 1 }
        )
    }
}

/// The backend `SdkHarness` scripts: the campaign bundle it serves, and an accepted answer to
/// everything else (track, session). Called by the network client on its own thread.
final class ScriptedBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var _campaigns: [[String: Any]]
    private var _bundleStatus = 200
    private var _bundleHeaders: [String: String] = [:]

    init(campaigns: [[String: Any]]) { _campaigns = campaigns }

    var campaigns: [[String: Any]] {
        get { lock.withLock { _campaigns } }
        set { lock.withLock { _campaigns = newValue } }
    }
    var bundleStatus: Int {
        get { lock.withLock { _bundleStatus } }
        set { lock.withLock { _bundleStatus = newValue } }
    }
    var bundleHeaders: [String: String] {
        get { lock.withLock { _bundleHeaders } }
        set { lock.withLock { _bundleHeaders = newValue } }
    }

    func answer(_ request: NetworkRequest) -> NetworkResponse {
        guard request.url.path.hasSuffix("/getCampaignBundle") else {
            let accepted = Data(#"{"accepted":1,"rejected":0,"errors":[]}"#.utf8)
            return NetworkResponse(statusCode: 200, headers: [:], body: accepted, isSuccessful: true)
        }
        let (campaigns, status, headers) = lock.withLock { (_campaigns, _bundleStatus, _bundleHeaders) }
        let body = try? JSONSerialization.data(withJSONObject: ["data": ["response": ["campaigns": campaigns]]])
        return NetworkResponse(
            statusCode: status, headers: headers, body: body, isSuccessful: (200..<300).contains(status))
    }
}

/// What a host-app handler received, in order: a box the `@Sendable` handlers can append to.
@MainActor
final class Received<Value> {
    var values: [Value] = []
    func append(_ value: Value) { values.append(value) }
}

/// Records every diagnostic record the SDK emits.
final class TimelineRecorder: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [TimelineRecord] = []

    var records: [TimelineRecord] { lock.withLock { _records } }

    func accepts(_ record: TimelineRecord) -> Bool { true }
    func emit(_ record: TimelineRecord) { lock.withLock { _records.append(record) } }
}

/// A shared SDK fixture by its path under `sdk_testing_fixtures/`, e.g. `actions/action_share.json`
/// or `campaigns/nudge_dialog/nudge_dialog.json`, with its media pointed at the Test Kit's mock
/// server. Mirrors `loadCampaign` in the Flutter harness.
func loadCampaign(_ path: String, file: StaticString = #filePath) throws -> [String: Any] {
    try #require(FixtureLoader.load(path, file: file), "Fixture \(path) not found or not a JSON object")
}

/// A shared campaign fixture by its path under `campaigns/`, without `.json`, e.g.
/// `engine/engine_rule_wait_cancel`.
func fixture(_ path: String, file: StaticString = #filePath) throws -> [String: Any] {
    try loadCampaign("campaigns/\(path).json", file: file)
}

/// The design tokens a fixture carries beside its campaign, as the campaign bundle carries its
/// `designTokens` beside `campaigns`. A fixture without them parses against an empty catalog, so a
/// token reference falls back to its authored default. Mirrors `_fixtureTokens` in the Flutter
/// harness.
func fixtureTokens(_ campaign: [String: Any]) -> DesignTokenCatalog {
    guard let tokens = campaign["designTokens"] as? [String: Any] else { return .empty }
    return (try? DesignTokenCatalog.fromJson(tokens)) ?? .empty
}

/// A fixture's `campaignKey`.
func keyOf(_ campaign: [String: Any]) -> String {
    campaign["campaignKey"] as? String ?? ""
}

/// Whether a test that needs campaign media (the PiP shows only once its image has loaded) can run:
/// the Test Kit is cloned beside this repo. Use as `.enabled(if: testkitAvailable, ...)`.
let testkitAvailable = FixtureLoader.workspaceURL().map {
    FileManager.default.fileExists(atPath: $0.appendingPathComponent("testkit/mock-server").path)
} ?? false
let testkitSkipReason: Comment = "Test Kit not found beside this repo; run `bash clone.sh` in de_workspace"
