import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

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
    private let plugin = FakeCep()
    private(set) var window: UIWindow?

    /// Boots the real SDK with [campaign] as the only campaign the server returns.
    static func start(
        _ campaign: [String: Any],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> SdkHarness {
        let harness = SdkHarness()
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

        Digia.register(harness.plugin)
        try await harness.waitUntil("the plugin is attached") { harness.plugin.host != nil }
        return harness
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
        let host = try #require(plugin.host)
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
    func tap(text: String) async throws {
        try await tap("text \(text)") { Self.shownText(of: $0)?.contains(text) == true }
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
        if let window { ComponentTestHost.cleanupOverlayWindow(window) }
        window = nil
        SDKInstance.shared.resetForTesting()
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

/// A CEP integration reduced to what it does in production: hold the host and hand it triggers.
private final class FakeCep: DigiaCEPPlugin {
    let id = "action-test"
    private(set) var host: DigiaCEPHost?

    func attach(host: DigiaCEPHost) { self.host = host }
    func detach() { host = nil }
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
