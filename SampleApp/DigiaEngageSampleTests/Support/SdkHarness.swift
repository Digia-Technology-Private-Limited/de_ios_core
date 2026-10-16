import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

/// Shared plumbing for the action tests in this folder.
///
/// Every test drives an action from the highest level a test reaches: the campaign comes from the
/// (mocked) server through the real `Digia.initialize`, a CEP plugin delivers it, the app's own
/// `DigiaHost` renders it, and a real touch (`TouchSynthesizer`) runs the action. Only the
/// boundaries outside the SDK are faked — the network (`MockNetworkClient` behind
/// `URLSessionNetworkClient.overrideForTesting`) and the OS (`ActionPlatform.current`) — so what a
/// test asserts is what the user would see or what the SDK asked iOS to do.
@MainActor
final class ActionHarness {

    /// The Test Kit has no fixture for most actions, so those tests reuse the `canvas-button-fill`
    /// inline card and swap the steps its button runs. The surface, layout and wire shape stay the
    /// shared fixture's.
    static let buttonCampaignKey = "test_canvas_button_fill"
    static let buttonSlotKey = "home_banner"
    static let buttonId = "canvas_btn_primary"

    let platform = RecordingPlatform()
    private let network = MockNetworkClient()
    private let plugin = ActionTestPlugin()
    private var window: UIWindow?

    /// Boots the real SDK with [campaign] as the only campaign the server returns.
    static func start(
        _ campaign: [String: Any],
        actionHandlers: DigiaActionHandlers = DigiaActionHandlers()
    ) async throws -> ActionHarness {
        let harness = ActionHarness()
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
        let window = try #require(window)
        var last: CGRect?
        var steadyReads = 0
        try await waitUntil("element \(id) settled on screen") {
            guard let frame = self.element(id: id)?.accessibilityFrame, !frame.isEmpty else { return false }
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
        return Self.find(in: window) { object in
            let shown: String? =
                (object as? UITextView)?.text ?? (object as? UILabel)?.text
                ?? object.accessibilityLabel ?? object.accessibilityValue
            return shown?.contains(text) == true
        } != nil
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

    private func element(id: String) -> NSObject? {
        guard let window else { return nil }
        return Self.find(in: window) { Self.identifier(of: $0) == id }
    }

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

/// Stands in for a CEP plugin (CleverTap, WebEngage, …): keeps the host the SDK attaches.
private final class ActionTestPlugin: DigiaCEPPlugin {
    let id = "action-test"
    private(set) var host: DigiaCEPHost?

    func attach(host: DigiaCEPHost) { self.host = host }
    func detach() { host = nil }
}

/// Test Kit campaigns, as JSON, for editing before the server "returns" them.
enum ActionCampaigns {

    static func load(_ campaignType: String, _ fileName: String) throws -> [String: Any] {
        try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fileName),
            "Test Kit fixture \(campaignType)/\(fileName) not found; run `bash clone.sh` in de_workspace")
    }

    /// `canvas-button-fill` with its button's `onClick` replaced by [steps].
    static func button(steps: [[String: Any]]) throws -> [String: Any] {
        var campaign = try load("canvas", "canvas-button-fill")
        try editCanvasChild(in: &campaign, id: ActionHarness.buttonId) { child in
            var widget = child["widget"] as? [String: Any] ?? [:]
            var props = widget["props"] as? [String: Any] ?? [:]
            props["onClick"] = ["steps": steps]
            widget["props"] = props
            child["widget"] = widget
        }
        return campaign
    }

    static func editCanvasChild(
        in campaign: inout [String: Any], id: String, _ edit: (inout [String: Any]) -> Void
    ) throws {
        try editChildren(in: &campaign) { children in
            let index = try #require(children.firstIndex { $0["id"] as? String == id }, "No canvas child \(id)")
            edit(&children[index])
        }
    }

    static func editChildren(
        in campaign: inout [String: Any], _ edit: (inout [[String: Any]]) throws -> Void
    ) throws {
        var template = try #require(campaign["templateConfig"] as? [String: Any])
        var canvas = try #require(template["canvas"] as? [String: Any])
        var children = try #require(canvas["children"] as? [[String: Any]])
        try edit(&children)
        canvas["children"] = children
        template["canvas"] = canvas
        campaign["templateConfig"] = template
    }
}
