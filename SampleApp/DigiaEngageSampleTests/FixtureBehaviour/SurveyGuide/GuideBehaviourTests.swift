import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What the guide fixtures do on a real screen: where a bubble goes when its side has no room, what
/// happens to an anchorless guide whose crop cannot be loaded, and what a tap outside the bubble does.
/// How long a first step waits and a guide the parser refuses are the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/GuideBehaviourTests.swift`. Each guide comes from the shared fixture, is delivered through the real SDK
/// and drawn by `DigiaHost` over `GuideAnchorsScreenSG`, which carries the anchors the fixtures
/// name.
///
/// The bubble is a canvas; its frame on screen is read from its `title` element, whose authored
/// rect in the step's canvas gives the canvas origin and scale. An anchor's frame is the SDK's
/// own (`AnchorRegistry.availableRect`), the rect the guide points at.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_guide_test.dart`.
@Suite("Guide: placement, delays, failures and outside taps", .serialized, .tags(.integration, .behaviour, .guide))
@MainActor
struct GuideBehaviourTests {

    private static let tooltips = "campaigns/guide_tooltip/guide_tooltip_"
    private static let spotlights = "campaigns/guide_spotlight/guide_spotlight_"

    /// Boots [path] over the anchors screen on `home` and delivers it.
    private func show(_ path: String) async throws -> SdkHarness {
        let sdk = try await SdkHarness.start(loadCampaign(path))
        try sdk.mount { GuideAnchorsScreenSG() }
        sdk.setCurrentScreen("home")
        try sdk.deliver(keyOf(try loadCampaign(path)))
        return sdk
    }

    private func waitShowing(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen", timeout: 4) { sdk.isShowing(text) }
    }

    /// The authored rect (fractions of its canvas) of the `title` of step [step] of [path].
    private func titleFraction(_ path: String, step: Int) throws -> CGRect {
        let template = try #require(try loadCampaign(path)["templateConfig"] as? [String: Any])
        let steps = try #require(template["steps"] as? [[String: Any]])
        let canvas = try #require(steps[step]["canvas"] as? [String: Any])
        let children = try #require(canvas["children"] as? [[String: Any]])
        let title = try #require(children.first { $0["id"] as? String == "title" })
        let r = try #require(title["rect"] as? [String: Double])
        return CGRect(x: r["x"]!, y: r["y"]!, width: r["width"]!, height: r["height"]!)
    }

    /// The bubble on screen now, from its title's frame and authored rect [fraction].
    private func bubble(_ sdk: SdkHarness, title fraction: CGRect) -> CGRect? {
        guard let window = sdk.window, let element = sdk.element(id: "title") else { return nil }
        let frame = window.convert(element.accessibilityFrame, from: window.screen.coordinateSpace)
        guard !frame.isEmpty else { return nil }
        let width = frame.width / fraction.width
        let height = frame.height / fraction.height
        return CGRect(x: frame.minX - fraction.minX * width, y: frame.minY - fraction.minY * height,
                      width: width, height: height)
    }

    private func anchor(_ key: String) throws -> CGRect {
        try #require(AnchorRegistry.shared.availableRect(for: key), "anchor \(key) on screen")
    }

    /// Waits for the bubble of step [step] to stop moving (a step's entry animation), then reads it.
    private func settledBubble(_ sdk: SdkHarness, _ path: String, step: Int) async throws -> CGRect {
        let fraction = try titleFraction(path, step: step)
        var last: CGRect?
        var steady = 0
        try await sdk.waitUntil("the bubble settled") {
            guard let rect = bubble(sdk, title: fraction) else { return false }
            steady = rect == last ? steady + 1 : 0
            last = rect
            return steady >= 6
        }
        return try #require(last)
    }

    // MARK: - A bubble with no room on its side

    // Fails if: guide_overlay_view.swift `guideCanvasPlacement` stops trying the other sides when
    // the preferred one has no room inside `safeBounds.insetBy(dx: 16, dy: 16)`.
    @Test("moves clear of a wishlist button that hugs the right edge")
    func edgeFlipMovesClear() async throws {
        let path = "\(Self.tooltips)edge_flip.json"
        let sdk = try await show(path)
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "No room above")
        try await sdk.tap(id: "cta_tap")
        try await waitShowing(sdk, "No room right")

        let box = try await settledBubble(sdk, path, step: 1)
        let screen = try #require(sdk.window).bounds
        #expect(screen.contains(box), "on screen, not past the right edge: \(box)")
        #expect(!box.intersects(try anchor("wishlist_icon_btn")), "it must not cover the button it points at")
    }

    // Fails if: guide_overlay_view.swift `guideCanvasPlacement` stops clamping a bubble that fits
    // on no side to the safe margins.
    @Test("stays inside the screen margins and off the seller row when it fits nowhere")
    func fitsNowhereStaysInside() async throws {
        let path = "\(Self.tooltips)oversize_capped.json"
        let sdk = try await show(path)
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Fits nowhere")

        let box = try await settledBubble(sdk, path, step: 0)
        let screen = try #require(sdk.window).bounds
        #expect(box.minX > 0)
        #expect(box.maxX < screen.width)
        #expect(box.maxY < screen.height)
        #expect(!box.intersects(try anchor("pdp_seller_info")), "beside or above the row it points at, never over it")
    }

    // Fails if: guide_overlay_view.swift `guideCanvasPlacement` stops scaling a bubble down to the
    // room beside its target.
    @Test("shrinks a tall bubble into the room beside its target")
    func tallBubbleShrinks() async throws {
        let path = "\(Self.tooltips)oversize_capped.json"
        let sdk = try await show(path)
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Fits nowhere")
        try await sdk.tap(id: "cta_tap")
        try await waitShowing(sdk, "Tall left")

        let box = try await settledBubble(sdk, path, step: 1)
        let screen = try #require(sdk.window).bounds
        let wishlist = try anchor("wishlist_icon_btn")
        #expect(box.maxX <= wishlist.minX + 0.5, "left of the wishlist button: \(box)")
        #expect(box.minX > 0)
        #expect(box.minY >= 0)
        #expect(box.maxY <= screen.height)
    }

    // MARK: - An anchorless guide whose crop cannot be loaded

    /// Serves every crop as a small PNG, except a URL containing `anchorless_crop_missing_404`,
    /// which answers 404 as the CDN would for a crop that was never uploaded. Mirrors
    /// `serveCropsExcept` in the Flutter suite.
    ///
    /// The fixture points its missing crop at the Test Kit's asset origin (plain http, or the bare
    /// `{{TESTKIT_ASSET_ORIGIN}}` placeholder without the Test Kit). iOS only accepts an https crop (`AnchorlessTarget.decode`: `imageURL.scheme == "https"`), so as authored the
    /// whole guide is unreadable and never reaches the store; a real crop is always on the https
    /// CDN. The loaded copy moves that one URL to https, keeping the file name the stub fails.
    private func showAnchorless(_ path: String) async throws -> SdkHarness {
        SGCropProtocol.failing = "anchorless_crop_missing_404"
        URLProtocol.registerClass(SGCropProtocol.self)
        let campaign = try httpsCrops(loadCampaign(path))
        let sdk = try await SdkHarness.start(campaign)
        try sdk.mount { GuideAnchorsScreenSG() }
        sdk.setCurrentScreen("home")
        #expect(sdk.sdk.campaignStore.keys.contains(keyOf(campaign)), "the guide is readable")
        try sdk.deliver(keyOf(campaign))
        return sdk
    }

    private func httpsCrops(_ campaign: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: campaign)
        let text = try #require(String(data: data, encoding: .utf8))
        let fixed = text.replacingOccurrences(
            of: #""imageUrl":"[^"]*anchorless_crop_missing_404\.png""#,
            with: #""imageUrl":"https://cdn.example.com/anchorless_crop_missing_404.png""#,
            options: .regularExpression)
        return try #require(try JSONSerialization.jsonObject(with: Data(fixed.utf8)) as? [String: Any])
    }

    private func endAnchorless(_ sdk: SdkHarness) {
        sdk.tearDown()
        URLProtocol.unregisterClass(SGCropProtocol.self)
    }

    // Fails if: guide_overlay_view.swift stops reporting `reportGuideRenderFailure` when the crop
    // fails to load (`guard let decoded = loaded.image else { ... }`), leaving the guide waiting.
    @Test("is dropped before its first step appears")
    func firstCropUnloadableDrops() async throws {
        let sdk = try await showAnchorless("campaigns/degradation/degrade_guide_anchorless_first_crop_unloadable.json")
        defer { endAnchorless(sdk) }

        try await sdk.waitUntil("dropped, not left waiting for its crop", timeout: 4) {
            SDKInstance.shared.guideOrchestrator.state == nil
        }
        #expect(!sdk.isShowing("Never shown"))
    }

    // Fails if: the same failure report stops ending the guide on a later step.
    @Test("ends when Next reaches the step whose crop cannot be loaded")
    func secondCropUnloadableEnds() async throws {
        let sdk = try await showAnchorless("campaigns/degradation/degrade_guide_anchorless_second_crop_unloadable.json")
        defer { endAnchorless(sdk) }
        try await waitShowing(sdk, "First step")

        try await sdk.tap(id: "cta_tap")

        try await sdk.waitUntil("the guide is over", timeout: 4) { SDKInstance.shared.guideOrchestrator.state == nil }
        #expect(!sdk.isShowing("Never shown"))
        #expect(!sdk.isShowing("First step"))
    }

    // MARK: - A tap outside the bubble

    /// A tap near the foot of the screen, far from every bubble.
    private func tapScrim(_ sdk: SdkHarness) throws {
        let window = try #require(sdk.window)
        try TouchSynthesizer.tap(at: CGPoint(x: window.bounds.midX, y: window.bounds.height - 64), in: window)
    }

    /// Lets the step take touches: it ignores them until it is presented.
    private func settleStep(_ sdk: SdkHarness) async throws {
        try await sdk.settle(0.5)
    }

    // Fails if: guide_overlay_view.swift's transparent background stops calling `onOutsideTap()`
    // for `outsideTapBehavior == .next`.
    @Test("advances a walkthrough to its next step")
    func outsideTapAdvances() async throws {
        let sdk = try await show("\(Self.tooltips)walkthrough.json")
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Quick Search")
        try await settleStep(sdk)

        try tapScrim(sdk)

        try await waitShowing(sdk, "Featured Deals")
        #expect(!sdk.isShowing("Quick Search"))
    }

    // Fails if: SDKInstance.swift `advanceGuide(completesOnLast: false)` stops ending the guide on
    // its last step.
    @Test("ends a one-step tooltip guide")
    func outsideTapEndsTooltip() async throws {
        let sdk = try await show("\(Self.tooltips)outside_dismiss.json")
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Tap Outside to Dismiss Tooltip")
        try await settleStep(sdk)

        try tapScrim(sdk)

        try await sdk.waitUntil("the tooltip is gone") { !sdk.isShowing("Tap Outside to Dismiss Tooltip") }
        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
    }

    // Fails if: guide_overlay_view.swift's spotlight scrim stops calling `onOutsideTap()` for
    // `outsideTapBehavior == .next`.
    @Test("ends a one-step spotlight guide")
    func outsideTapEndsSpotlight() async throws {
        let sdk = try await show("\(Self.spotlights)outside_dismiss.json")
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Tap Outside to Dismiss Spotlight")
        try await settleStep(sdk)

        try tapScrim(sdk)

        try await sdk.waitUntil("the spotlight is gone") { !sdk.isShowing("Tap Outside to Dismiss Spotlight") }
        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
    }

    // Fails if: guide_overlay_view.swift's transparent background advances on any outside tap
    // (the `if config.outsideTapBehavior == .next` guard is dropped).
    @Test("is swallowed by a tooltip guide that authored `nothing`; only its button leaves")
    func tooltipNothingSwallows() async throws {
        let sdk = try await show("\(Self.tooltips)mutex.json")
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Primary Active Tooltip")
        try await settleStep(sdk)

        try tapScrim(sdk)
        try await sdk.settle(0.6)
        #expect(sdk.isShowing("Primary Active Tooltip"))

        try await sdk.tap(id: "cta_dismiss")
        try await sdk.waitUntil("the tooltip is gone") { !sdk.isShowing("Primary Active Tooltip") }
    }

    // Fails if: guide_overlay_view.swift's spotlight scrim advances on any outside tap.
    @Test("is swallowed when the guide authored `nothing`; only its button leaves")
    func spotlightNothingSwallows() async throws {
        let sdk = try await show("\(Self.spotlights)touch_model.json")
        defer { sdk.tearDown() }
        try await waitShowing(sdk, "Guarded Spotlight")
        try await settleStep(sdk)

        try tapScrim(sdk)
        try await sdk.settle(0.6)
        #expect(sdk.isShowing("Guarded Spotlight"))

        try await sdk.tap(id: "cta_got_it")
        try await sdk.waitUntil("the spotlight is gone") { !sdk.isShowing("Guarded Spotlight") }
    }
}
}

/// Serves every crop an anchorless guide fetches as a small PNG, except a URL containing
/// [failing], which answers 404.
final class SGCropProtocol: URLProtocol {
    nonisolated(unsafe) static var failing = ""

    private static let png: Data = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }.pngData() ?? Data()

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return url.path.contains("anchorless") || url.path.hasSuffix(".png")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let missing = !Self.failing.isEmpty && url.absoluteString.contains(Self.failing)
        let response = HTTPURLResponse(url: url, statusCode: missing ? 404 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: missing ? Data() : Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
