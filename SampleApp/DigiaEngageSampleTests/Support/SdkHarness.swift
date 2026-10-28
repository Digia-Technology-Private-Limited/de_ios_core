import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// The SDK is a process singleton and the tests share one app, one window scene and one pasteboard, but Swift
/// Testing runs separate suites in parallel. This lets one test at a time hold them, whatever suite it is in.
actor SdkGate {
    static let shared = SdkGate()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
}

/// Drives the real SDK over a scripted backend; the one harness for every suite here that needs a
/// running SDK. Mirrors `flutter/core/test/support/sdk_harness.dart`.
///
/// Every test drives an action from the highest level a test reaches: the campaign comes from the
/// (mocked) server through the real `Digia.initialize`, a CEP plugin delivers it, the app's own
/// `DigiaHost` renders it, and a real touch (`TouchSynthesizer`) runs the action. Only the
/// boundaries outside the SDK are faked — the network (`MockNetworkClient` behind
/// `URLSessionNetworkClient.overrideForTesting`) and the OS (`ActionPlatform.current`, recorded by
/// `RecordingPlatform` in `PlatformFakes.swift`) — so what a test asserts is what the user would see
/// or what the SDK asked iOS to do.
@MainActor
final class SdkHarness {

    /// The `actions/fixtures/action_*` inline cards (all but the story and surface-specific ones)
    /// share this slot and button; only the steps the button runs differ.
    static let buttonSlotKey = "home_banner"
    static let buttonId = "canvas_btn_primary"

    let platform = RecordingPlatform()
    private let network = MockNetworkClient()
    let cep = FakeCep()
    private(set) var window: UIWindow!
    /// Whether the campaigns come from the workspace fixtures through `StubBackend` (see
    /// ``start(_:actionHandlers:backend:content:)``), rather than the in-process `MockNetworkClient`.
    private var usesStubBackend = false

    /// Boots the real SDK with [campaign] as the only campaign the server returns.
    static func start(
        _ campaign: [String: Any],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> SdkHarness {
        await SdkGate.shared.enter()
        let harness = SdkHarness()
        do {
            try await harness.boot(campaign, actionHandlers: actionHandlers)
        } catch {
            harness.tearDown()
            throw error
        }
        return harness
    }

    private func boot(_ campaign: [String: Any], actionHandlers: DigiaActionHandlers) async throws {
        let harness = self
        let sdk = SDKInstance.shared
        sdk.resetForTesting()
        ComponentTestHost.enableAccessibilityAutomation()

        let bundle = try JSONSerialization.data(withJSONObject: ["campaigns": [campaign]])
        harness.network.setResponseFactory { request in
            let body = request.url.path.hasSuffix("/getCampaignBundle") ? bundle : Data("{}".utf8)
            return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
        }
        let client = try #require(sdk.networkClient as? URLSessionNetworkClient)
        client.overrideForTesting = harness.network
        ActionPlatform.current = harness.platform.actionPlatform

        try await Digia.initialize(DigiaConfig(apiKey: "test-api-key", actionHandlers: actionHandlers))
        try #require(sdk.sdkState == .ready, "initialize did not reach ready: \(sdk.sdkState)")

        Digia.register(harness.cep)
        try await harness.waitUntil("the plugin is attached") { harness.cep.host != nil }
    }

    /// Boots the SDK serving `campaigns` (the shared workspace fixtures) through `StubBackend`, with a
    /// CEP plugin attached and `content` under the `DigiaHost`. Use `cep.deliver` to fire a campaign.
    static func start<Content: View>(
        _ campaigns: [WorkspaceFixtures.Campaign],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers(),
        backend: StubBackend.Options = StubBackend.Options(),
        @ViewBuilder content: () -> Content
    ) async throws -> SdkHarness {
        await SdkGate.shared.enter()
        let harness = SdkHarness()
        harness.usesStubBackend = true
        // First, so the SDK's network client is built on a configuration that carries the stub.
        StubBackend.install(campaigns: campaigns.map(\.json), options: backend)
        UserDefaults(suiteName: "tech.digia.engage")?.removePersistentDomain(forName: "tech.digia.engage")
        SDKInstance.shared.resetForTesting()
        do {
            try await Digia.initialize(DigiaConfig(apiKey: "test-api-key", actionHandlers: actionHandlers))
            SDKInstance.shared.register(harness.cep)
        } catch {
            harness.tearDown()
            throw error
        }
        harness.mountFullScreen(content())
        return harness
    }

    private func mountFullScreen<Content: View>(_ content: Content) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        let window = UIWindow(windowScene: scene)
        // Full screen, like the app's own window: the floater and PiP take the screen box and safe area from
        // the app's window, so a smaller test window would be laid out for a screen it is not.
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: DigiaHost { content })
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        self.window = window
    }

    /// Lets the run loop turn for `seconds`, so layout, animations and image loads finish.
    func settle(_ seconds: TimeInterval = 1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Serves every PiP video from the Test Kit's file through a player that never plays; see `PausedPlayer`.
    func useStillVideo() {
        SDKInstance.shared.floaterOrchestrator.playerFactory = { PausedPlayer(forRemote: $0) }
    }

    /// Mounts the app the way the integration guide tells customers to: `DigiaHost` around the
    /// app's own content, in a key window of the host app's scene.
    func mount<Content: View>(@ViewBuilder _ content: () -> Content) throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "No window scene: run in the sample app host")
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        let host = UIHostingController(rootView: DigiaHost(content: content))
        window.rootViewController = host
        window.makeKeyAndVisible()
        TouchSynthesizer.drainRunLoop(for: 0.3)
        self.window = window
    }

    /// What the CEP does when its campaign fires. The handle reports how the showing ended.
    @discardableResult
    func deliver(_ campaignKey: String) throws -> CampaignPresentation {
        let host = try #require(cep.host)
        return host.deliver(CEPTriggerPayload(
            cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:]))
    }

    /// A real touch at the centre of the canvas element authored with [id] (`TestView` sets it as
    /// the accessibility identifier in debug builds). Waits for the element to stop moving first: a
    /// surface's entry animation would otherwise send the touch to where the element *was*.
    ///
    /// The frame must also hold for 400 ms, not just a few reads. SwiftUI lists a just-presented
    /// element in the accessibility tree, at its final frame, before the surface takes touches:
    /// the canvas dialog nudge sent a touch at that moment to its backdrop 2–4 times in 10, while
    /// waiting 400 ms passed 10 in 10. There is no public signal for "accepts touches", and
    /// Core Animation sees no running animation then either.
    func tap(id: String) async throws {
        try await tap("element \(id)") { Self.identifier(of: $0) == id }
    }

    /// As ``tap(id:)``, for the element that shows [text] (an option label has no id of its own).
    ///
    /// A harness started from workspace fixtures finds the text with `UIProbe` instead, and settles after.
    func tap(text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        guard usesStubBackend else {
            try await tap("text \(text)") { Self.shownText(of: $0)?.contains(text) == true }
            return
        }
        let point = try #require(
            UIProbe.center(ofText: text, in: window), "nothing on screen shows \"\(text)\"",
            sourceLocation: sourceLocation)
        try TouchSynthesizer.tap(at: point, in: window)
        await settle(0.5)
    }

    /// As ``tap(id:)``, for the element whose shown text or accessibility label is exactly [label]: an SDK glyph
    /// ("Close") or a SwiftUI text, which ``tap(text:)`` does not see in a harness started from workspace fixtures.
    func tap(label: String) async throws {
        try await tap("label \(label)") { Self.shownText(of: $0) == label }
        await settle(0.5)
    }

    private func tap(_ what: String, where match: @escaping (NSObject) -> Bool) async throws {
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("\(what) settled on screen") {
            guard let frame = Self.find(in: window, where: match)?.accessibilityFrame, !frame.isEmpty
            else { return false }
            steadyReads = frame == last ? steadyReads + 1 : 0
            last = frame
            return steadyReads >= 8 // 8 reads, 50 ms apart
        }
        let frame = window.convert(try #require(last), from: window.screen.coordinateSpace)
        try TouchSynthesizer.tap(at: CGPoint(x: frame.midX, y: frame.midY), in: window)
    }

    /// Whether [text] is on screen: in a visible text view or label (canvas text is a `UITextView`)
    /// or read out by an accessibility element.
    func isShowing(_ text: String) -> Bool {
        guard let window else { return false }
        return Self.find(in: window) { Self.shownText(of: $0)?.contains(text) == true } != nil
    }

    private static func shownText(of object: NSObject) -> String? {
        (object as? UITextView)?.text ?? (object as? UILabel)?.text
            ?? object.accessibilityLabel ?? object.accessibilityValue
    }

    /// The view controller presented over the app (a full-screen viewer, a sheet), if any.
    var presentedViewer: UIViewController? {
        window?.rootViewController?.presentedViewController
    }

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

    func tearDown() {
        SDKInstance.shared.floaterOrchestrator.playerFactory = nil
        if let window {
            if usesStubBackend { window.isHidden = true } else { ComponentTestHost.cleanupOverlayWindow(window) }
        }
        window = nil
        SDKInstance.shared.resetForTesting()
        if usesStubBackend { StubBackend.uninstall() }
        Task { await SdkGate.shared.leave() }
    }

    // MARK: - Accessibility tree

    private static func identifier(of object: NSObject) -> String? {
        let selector = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private static func find(in root: NSObject, depth: Int = 0, where match: (NSObject) -> Bool) -> NSObject? {
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

/// The campaign fixture at [path], relative to this test target's folder, e.g.
/// `Actions/Fixtures/action_share.json` or `Campaigns/nudge_dialog/fixtures/nudge-dialog.json`,
/// with its media pointed at the Test Kit's mock server (see ``testkitSkipReason``).
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
