import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Drives the real SDK the way a customer's app does; the one harness for every suite that delivers
/// a campaign through a CEP. Spec: `ai_docs/sdk-harness.md` in de_workspace. The Android and
/// Flutter harnesses have the same core members with the same meaning.
///
/// The campaign bundle comes from a mocked server through the real `Digia.initialize`, `FakeCep`
/// delivers a campaign, the app's own `DigiaHost` renders it, and the test asserts on what the user
/// would see or on how the showing ended. Only the boundaries outside the SDK are faked: the
/// network (`MockNetworkClient` behind `URLSessionNetworkClient.overrideForTesting`), the CEP
/// (`FakeCep`) and the OS (`ActionPlatform.current`, recorded by `RecordingPlatform`).
///
/// This file is compiled into the package's test target and, through the Xcode project, into the
/// SampleApp's. Touches (`tap(id:)`, `tap(text:)`) and `presentedViewer` need the sample app host
/// and live in `SampleApp/DigiaEngageSampleTests/Support/SdkHarness+Touch.swift`.
@MainActor
final class SdkHarness {

    /// The `actions/fixtures/action_*` inline cards (all but the story and surface-specific ones)
    /// share this slot and button; only the steps the button runs differ.
    static let buttonSlotKey = "home_banner"
    static let buttonId = "canvas_btn_primary"

    /// The CEP plugin, registered by `start` and `startHeld`.
    let cep = FakeCep()
    /// Every request the SDK sent, in order.
    let network = MockNetworkClient()
    /// The recorded OS boundary: URLs opened, text copied and shared, review requests.
    let platform = RecordingPlatform()
    /// The key window `mount` put the app in.
    private(set) var window: UIWindow?

    private let server: BundleServer
    private let actionHandlers: DigiaActionHandlers
    private var initialization: Task<Void, Never>?

    private init(actionHandlers: DigiaActionHandlers) {
        server = BundleServer(network)
        self.actionHandlers = actionHandlers
    }

    // MARK: - Boot

    /// Resets the SDK, serves `campaigns` as the bundle, runs the real `initialize` over the mock
    /// network, waits for READY, then registers `cep` and waits for it to attach.
    static func start(
        _ campaigns: [String: Any]...,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> SdkHarness {
        let harness = try SdkHarness.reset(campaigns, actionHandlers: actionHandlers)
        try await harness.initialize()
        return harness
    }

    /// As `start`, but registers `cep` before `initialize` and holds the bundle fetch. Returns
    /// while the SDK is still initializing; `releaseBundle()` lets it finish.
    static func startHeld(
        _ campaigns: [String: Any]...,
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> SdkHarness {
        let harness = try SdkHarness.reset(campaigns, actionHandlers: actionHandlers)
        harness.server.hold()
        Digia.register(harness.cep)
        let config = harness.config
        harness.initialization = Task { try? await Digia.initialize(config) }
        try await harness.waitUntil("the SDK is initializing with FakeCep attached") {
            SDKInstance.shared.sdkState == .initializing && harness.cep.host != nil
        }
        return harness
    }

    /// Answers the held bundle fetch, then waits for READY and for `cep` to flush its buffer.
    func releaseBundle() async throws {
        server.release()
        try await waitUntil("the SDK is READY") { SDKInstance.shared.sdkState == .ready }
        try await waitUntil("FakeCep flushed its buffer") { cep.buffered == 0 }
        await initialization?.value
        initialization = nil
    }

    /// Replaces what the bundle endpoint returns from now on: for `startHeld` before release, and
    /// for `relaunch()`.
    func serve(_ campaigns: [String: Any]...) throws {
        try serve(campaigns)
    }

    /// The process dies and the app opens again over the same storage: reset, then the real
    /// `initialize` again, serving the current bundle. `cep` is registered again, as the app's
    /// startup would.
    func relaunch() async throws {
        SDKInstance.shared.resetForTesting()
        try install()
        try await initialize()
    }

    private static func reset(
        _ campaigns: [[String: Any]], actionHandlers: DigiaActionHandlers
    ) throws -> SdkHarness {
        SDKInstance.shared.resetForTesting()
        ComponentTestHost.enableAccessibilityAutomation()
        let harness = SdkHarness(actionHandlers: actionHandlers)
        try harness.serve(campaigns)
        try harness.install()
        return harness
    }

    private func serve(_ campaigns: [[String: Any]]) throws {
        server.bundle = try JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
    }

    /// The fakes `resetForTesting` takes out again.
    private func install() throws {
        let client = try #require(SDKInstance.shared.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = server
        ActionPlatform.current = platform.actionPlatform
    }

    private var config: DigiaConfig {
        DigiaConfig(apiKey: "test-api-key", actionHandlers: actionHandlers)
    }

    private func initialize() async throws {
        let sdk = SDKInstance.shared
        try await Digia.initialize(config)
        try #require(sdk.sdkState == .ready, "initialize did not reach ready: \(sdk.sdkState)")
        Digia.register(cep)
        try await waitUntil("FakeCep is attached") { cep.host != nil }
    }

    // MARK: - Delivery

    /// What the CEP does when its rule fires for `campaignKey`, once the SDK is READY:
    /// `cep.receive(campaignKey)`. The presentation reports how the showing ended.
    @discardableResult
    func deliver(_ campaignKey: String) throws -> CampaignPresentation {
        try #require(SDKInstance.shared.isReady, "deliver(\(campaignKey)) before READY; use startHeld")
        return try #require(cep.receive(campaignKey))
    }

    /// How the showing ended, or nil while it is still running. Never blocks.
    func outcome(of presentation: CampaignPresentation) -> PresentationOutcome? {
        presentation.outcome.settledValue
    }

    // MARK: - Screen

    /// Mounts the app the way the integration guide tells customers to: `DigiaHost` around the
    /// app's own content, in a key window. In the sample app that window is in the app's scene;
    /// the package's test bundle has no scene, so it is a free-standing screen-sized window, as
    /// `ComponentTestHost` uses.
    func mount<Content: View>(@ViewBuilder _ content: () -> Content) throws {
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = scene.screen.bounds
        } else {
            window = UIWindow(frame: UIScreen.main.bounds)
        }
        window.rootViewController = UIHostingController(rootView: DigiaHost(content: content))
        window.makeKeyAndVisible()
        ComponentTestHost.drainRunLoop(for: 0.3)
        self.window = window
    }

    /// Whether `text` is on screen: in a visible text view or label (canvas text is a
    /// `UITextView`) or read out by an accessibility element.
    func isShowing(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0)?.contains(text) == true } != nil
    }

    // MARK: - Time

    /// Polls `condition` until it holds; fails the test naming `what` on timeout.
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

    struct TimedOut: Error {}

    /// Lets pending SDK work (fire-and-forget reports, main-thread hops) finish.
    func settle() async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<10 { await Task.yield() }
    }

    /// Dismisses every surface and resets the SDK and the fakes this harness installed.
    func tearDown() {
        server.release()
        initialization?.cancel()
        initialization = nil
        if let window { ComponentTestHost.cleanupOverlayWindow(window) }
        window = nil
        SDKInstance.shared.resetForTesting()
    }

    // MARK: - What the SDK sent

    /// Every tracked event sent, in order, decoded.
    var events: [[String: Any]] {
        bodies(sentTo: "/api/v1/engage/sdk/track").flatMap { $0["events"] as? [[String: Any]] ?? [] }
    }

    /// Every `/session` body sent, in order, decoded.
    var reports: [[String: Any]] {
        bodies(sentTo: "/api/v1/engage/sdk/session")
    }

    private func bodies(sentTo path: String) -> [[String: Any]] {
        network.recordedRequests
            .filter { $0.url.path.hasSuffix(path) }
            .compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
    }

    // MARK: - Accessibility tree

    static func shownText(of object: NSObject) -> String? {
        (object as? UITextView)?.text ?? (object as? UILabel)?.text
            ?? object.accessibilityLabel ?? object.accessibilityValue
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

/// A CEP integration reduced to what it does in production: hold the host, hand it triggers, and
/// buffer what arrives before the host is ready.
@MainActor
final class FakeCep: DigiaCEPPlugin {
    let id = "fake-cep"
    private(set) var host: DigiaCEPHost?
    /// Every presentation it delivered, in delivery order, with the campaign key.
    private(set) var presentations: [(campaignKey: String, presentation: CampaignPresentation)] = []
    private let buffer: PendingPayloadBuffer

    init() {
        buffer = PendingPayloadBuffer(onDrop: { _, _ in })
    }

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

/// The SDK's network: answers the bundle endpoint with what `serve` set, and every other endpoint
/// with an empty success, recording every request in `MockNetworkClient`. While held, a bundle
/// fetch waits (and is recorded) until `release()`.
private final class BundleServer: NetworkClient, @unchecked Sendable {
    private let mock: MockNetworkClient
    private let lock = NSLock()
    private var _bundle = Data()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ mock: MockNetworkClient) {
        self.mock = mock
        mock.setResponseFactory { [unowned self] request in
            let body = Self.isBundle(request) ? self.bundle : Data("{}".utf8)
            return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
        }
    }

    var bundle: Data {
        get { locked { _bundle } }
        set { locked { _bundle = newValue } }
    }

    // `NSLock.withLock` needs iOS 16; the package supports iOS 15.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func hold() { locked { held = true } }

    func release() {
        let pending = locked {
            held = false
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume() }
    }

    private static func isBundle(_ request: NetworkRequest) -> Bool {
        request.url.path.hasSuffix("/getCampaignBundle")
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        if Self.isBundle(request) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let wait = locked {
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

/// The campaign fixture at `path`, relative to the caller's test target folder (the folder above
/// the caller's own), e.g. `Actions/Fixtures/action_share.json` or
/// `Campaigns/nudge_dialog/fixtures/nudge-dialog.json` from a SampleApp suite in `Actions/`, with
/// its media pointed at the Test Kit's mock server (see ``testkitSkipReason``).
///
/// Read from the source tree rather than the bundle: the simulator shares the Mac's filesystem,
/// and a synchronized folder would flatten the fixture directories.
func loadCampaign(_ path: String, file: StaticString = #filePath) throws -> [String: Any] {
    let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent(path))
    let raw = try #require(String(data: data, encoding: .utf8))
    let resolved = FixtureLoader.resolveAssetOrigin(in: raw, workspaceUrl: testkitWorkspace(file: file))
    return try #require(
        try JSONSerialization.jsonObject(with: Data(resolved.utf8)) as? [String: Any],
        "Fixture \(path) is not a JSON object")
}

/// The workspace Test Kit still owns the media the fixtures point at; this package is cloned at
/// `<workspace>/ios/core`.
private func testkitWorkspace(file: StaticString) -> URL? {
    var url = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
    for _ in 0..<12 {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("testkit/mock-server").path) {
            return url
        }
        url = url.deletingLastPathComponent()
    }
    return nil
}

/// Whether a test that needs campaign media (the PiP shows only once its image has loaded) can run:
/// the Test Kit is cloned beside this repo. Use as `.enabled(if: testkitAvailable, ...)`.
let testkitAvailable = testkitWorkspace(file: #filePath) != nil
let testkitSkipReason: Comment = "Test Kit not found beside this repo; run `bash clone.sh` in de_workspace"
