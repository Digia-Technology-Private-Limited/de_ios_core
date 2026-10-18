import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit tooltip and spotlight guide fixture.
///
/// The arguments are read from `testkit/campaigns/guide_tooltip/` and `guide_spotlight/`
/// `fixtures/`, so a fixture added to the Test Kit is covered with no code change
/// (record it with `RECORD_SNAPSHOTS=true ./run-tests.sh guide`). Each fixture is decoded by
/// `CampaignModel.fromJson` for iOS, started on the SDK's guide orchestrator, and drawn by the
/// production `GuideOverlayView` — the layer `DigiaHost` mounts — over a host screen whose anchors
/// register through `DigiaAnchorView`, as an app's do. A golden shows the guide's first step.
///
/// `testkit/campaigns/anchorless/` is not covered: `GuideOverlayView` resolves an anchorless
/// target against `ViewControllerUtil.keyWindow()`, which needs a connected `UIWindowScene`, and
/// the test bundle has no host app and so no scene; every anchorless step fails with
/// `invalidGeometry` before it draws. It is covered by `AnchorlessFixtureGoldenTests` in the
/// sample-app-hosted target, which has a scene.
@Suite("Test Kit guide fixture goldens", .serialized, .tags(.guide))
struct GuideFixtureGoldenTests {

    /// Fixtures this SDK draws nothing for. Each is asserted to stay invisible, and fails once it
    /// draws so it can get a golden instead.
    ///   - classic-layout tooltips: the native overlay draws only `layoutMode: canvas` steps;
    ///   - a step whose anchor is not on screen.
    private static let drawsNothing: Set<String> = [
        "guide_tooltip/guide-tooltip-classic-stack-push",
        "guide_spotlight/guide-spotlight-missing",
    ]

    private static func fixtures(_ campaignType: String) -> [String] {
        FixtureLoader.fixtureNames(campaignType: campaignType)
            .filter { !drawsNothing.contains("\(campaignType)/\($0)") }
    }

    @Test("matches the tooltip fixture golden", .tags(.golden), arguments: fixtures("guide_tooltip"))
    @MainActor
    func testTooltipFixtureGolden(fixture: String) async throws {
        try await assertGuideFixture(fixture, campaignType: "guide_tooltip", function: "testTooltipFixtureGolden")
    }

    @Test("matches the spotlight fixture golden", .tags(.golden), arguments: fixtures("guide_spotlight"))
    @MainActor
    func testSpotlightFixtureGolden(fixture: String) async throws {
        try await assertGuideFixture(fixture, campaignType: "guide_spotlight", function: "testSpotlightFixtureGolden")
    }

    @Test("draws nothing for a guide this SDK cannot show", .tags(.component), arguments: drawsNothing.sorted())
    @MainActor
    func testGuideFixtureDrawsNothing(path: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        let json = try #require(FixtureLoader.loadFixture(campaignType: parts[0], fileName: parts[1]))
        // A fixture the parser rejects never reaches the screen.
        guard let campaign = try CampaignModel.fromJson(json, devicePlatform: "ios") else { return }

        let showing = try showGuide(campaign)
        defer { showing.end() }
        // Past the anchor readiness timeout (2s).
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(
            ComponentTestHost.renderImage(of: showing.window).pngData() == showing.hostOnly.pngData(),
            "\(path) now draws; remove it from `drawsNothing` so it gets a golden"
        )
    }

    /// Snapshot file: `__Snapshots__/GuideFixtureGoldenTests/<test>.<fixture>.png`.
    @MainActor
    private func assertGuideFixture(_ fixture: String, campaignType: String, function: StaticString) async throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let campaign = try #require(
            try CampaignModel.fromJson(json, devicePlatform: "ios"),
            "Fixture must decode to a guide"
        )
        try #require(campaign.guideConfig != nil, "Fixture must decode to a guide")

        let showing = try showGuide(campaign)
        defer { showing.end() }

        // The step stays transparent until its anchor is tracked and its callout measured; wait for it to draw (at most 3s) rather than for a fixed time.
        var drawn = false
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 100_000_000)
            drawn = ComponentTestHost.renderImage(of: showing.window).pngData() != showing.hostOnly.pngData()
            if drawn { break }
        }
        try #require(drawn, "The guide drew nothing")

        // Exact within the perceptual tolerance, as the other fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: showing.window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: function
        )
    }

    // MARK: - Showing a guide

    @MainActor
    private struct Showing {
        let window: UIWindow
        /// The host screen before the guide started.
        let hostOnly: UIImage
        let end: @MainActor () -> Void
    }

    /// Puts the host screen and `GuideOverlayView` in a key window, then starts [campaign] on the
    /// SDK's guide orchestrator.
    @MainActor
    private func showGuide(_ campaign: CampaignModel) throws -> Showing {
        let window = makeGuideWindow(device: .iPhone17ProMax)
        let hostOnly = ComponentTestHost.renderImage(of: window)

        let orchestrator = SDKInstance.shared.guideOrchestrator
        // Each fixture its own campaign id, so no dwell carries over from the previous one.
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "test_guide_\(campaign.campaignKey)", campaignKey: campaign.campaignKey, cepMetadata: [:])
        )
        let end: @MainActor () -> Void = {
            // SDKInstance is process-wide; end the showing so the next fixture can start.
            orchestrator.dismiss()
            ComponentTestHost.cleanupOverlayWindow(window)
        }
        guard started else {
            end()
            throw GuideNotStarted()
        }
        return Showing(window: window, hostOnly: hostOnly, end: end)
    }

    private struct GuideNotStarted: Error {}

    /// A key window with the guide layer over a host screen, as `DigiaHost` stacks them.
    @MainActor
    private func makeGuideWindow(device: ViewImageConfig) -> UIWindow {
        let size = device.size!
        let window =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)

        let rootVC = ComponentTestHost.makeDeviceHost(
            device: device,
            style: .solid(UIColor(white: 0.96, alpha: 1)),
            scrimColor: nil,
            showHomeIndicator: false
        )
        addHostAnchors(to: rootVC.view, width: size.width)

        let overlayVC = UIHostingController(rootView: GuideOverlayView())
        overlayVC.view.frame = CGRect(origin: .zero, size: size)
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        ComponentTestHost.drainRunLoop(for: 0.2)
        return window
    }

    /// The Test Kit app's anchors, at fixed places on a home-like screen below the notch, each
    /// registered by a `DigiaAnchorView` when the window shows.
    @MainActor
    private func addHostAnchors(to view: UIView, width: CGFloat) {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: width, height: 120))
        header.backgroundColor = .white
        view.addSubview(header)

        let anchors: [(key: String, frame: CGRect, title: String, color: UIColor)] = [
            ("home_header_search", CGRect(x: 16, y: 68, width: 352, height: 40), "Search products",
             UIColor(white: 0.90, alpha: 1)),
            ("wishlist_icon_btn", CGRect(x: 380, y: 68, width: 44, height: 40), "♡",
             UIColor(red: 0xFC / 255, green: 0xE7 / 255, blue: 0xF3 / 255, alpha: 1)),
            ("category_chips", CGRect(x: 16, y: 136, width: 408, height: 36), "Fruits · Dairy · Bakery · Snacks",
             UIColor(red: 0xE0 / 255, green: 0xE7 / 255, blue: 0xFF / 255, alpha: 1)),
            ("home_carousel", CGRect(x: 16, y: 340, width: 408, height: 180), "Featured carousel",
             UIColor(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255, alpha: 1)),
            ("pdp_seller_info", CGRect(x: 16, y: 780, width: 408, height: 72), "Seller info",
             UIColor(red: 0xFF / 255, green: 0xCA / 255, blue: 0x28 / 255, alpha: 1)),
        ]
        for anchor in anchors {
            let label = UILabel(frame: CGRect(origin: .zero, size: anchor.frame.size))
            label.text = anchor.title
            label.textAlignment = .center
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = UIColor(white: 0.15, alpha: 1)
            label.backgroundColor = anchor.color
            label.layer.cornerRadius = 8
            label.clipsToBounds = true

            let anchorView = DigiaAnchorView(frame: anchor.frame)
            anchorView.addSubview(label)
            anchorView.anchorKey = anchor.key
            view.addSubview(anchorView)
        }
    }
}
}
