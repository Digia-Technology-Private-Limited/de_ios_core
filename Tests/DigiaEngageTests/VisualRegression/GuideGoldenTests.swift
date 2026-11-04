import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit tooltip and spotlight guide fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/guide_tooltip/` and
/// `guide_spotlight/`, so a fixture added to the Test Kit is covered with no code change
/// (record it with `RECORD_SNAPSHOTS=true ./run-tests.sh guide`). Each fixture is decoded by
/// `CampaignModel.fromJson` for iOS, started on the SDK's guide orchestrator, and drawn by the
/// production `GuideOverlayView` — the layer `DigiaHost` mounts — over a host screen whose anchors
/// register through `DigiaAnchorView`, as an app's do. A golden shows the guide's first step.
///
/// `sdk_testing_fixtures/campaigns/anchorless/` is not covered: `GuideOverlayView` resolves an anchorless
/// target against `ViewControllerUtil.keyWindow()`, which needs a connected `UIWindowScene`, and
/// the test bundle has no host app and so no scene; every anchorless step fails with
/// `invalidGeometry` before it draws. It is covered by `AnchorlessGoldenTests` in the
/// sample-app-hosted target, which has a scene.
@Suite("Test Kit guide fixture goldens", .serialized, .tags(.guide))
struct GuideGoldenTests {

    /// Fixtures this SDK draws nothing for. Each is asserted to stay invisible, and fails once it
    /// draws; the bare host screen is also its golden, proving nothing was drawn, recorded under the
    /// sibling fixture test's name.
    ///   - classic-layout tooltips: the native overlay draws only `layoutMode: canvas` steps;
    ///   - a step whose anchor is not on screen.
    private static let drawsNothing: Set<String> = [
        "guide_tooltip/guide_tooltip_classic_stack_push",
        "guide_spotlight/guide_spotlight_missing",
    ]

    private static func fixtures(_ campaignType: String) -> [String] {
        FixtureLoader.fixtureNames(campaignType: campaignType)
            .filter { !drawsNothing.contains("\(campaignType)/\($0)") }
    }

    @Test("matches the tooltip fixture golden", .tags(.golden), arguments: fixtures("guide_tooltip"))
    @MainActor
    func testTooltipFixtureGolden(fixture: String) async throws {
        try await assertGuideFixture(fixture, campaignType: "guide_tooltip")
    }

    @Test("matches the spotlight fixture golden", .tags(.golden), arguments: fixtures("guide_spotlight"))
    @MainActor
    func testSpotlightFixtureGolden(fixture: String) async throws {
        try await assertGuideFixture(fixture, campaignType: "guide_spotlight")
    }

    @Test("draws nothing for a guide this SDK cannot show", .tags(.component, .golden), arguments: drawsNothing.sorted())
    @MainActor
    func testGuideFixtureDrawsNothing(path: String) async throws {
        let parts = path.split(separator: "/").map(String.init)
        let json = try #require(FixtureLoader.loadFixture(campaignType: parts[0], fileName: parts[1]))
        // A fixture the parser rejects never reaches the screen.
        guard let campaign = try CampaignModel.fromJson(json, designTokens: fixtureTokens(json), devicePlatform: "ios") else { return }

        let showing = try showGuide(campaign)
        defer { showing.end() }
        // Past the anchor readiness timeout (2s).
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(
            ComponentTestHost.renderImage(of: showing.window).pngData() == showing.hostOnly.pngData(),
            "\(path) now draws; remove it from `drawsNothing` so the regular golden test covers it"
        )
        // The bare host screen is the golden too: it proves nothing was drawn.
        let settled = ComponentTestHost.settledImage(of: showing.window)
        assertSurfaceGolden(settled, surface: parts[0], named: parts[1], precision: 1.0, perceptualPrecision: 0.98)
    }

    /// Snapshot file: `de_workspace/goldens/ios/<campaignType>/<fixture>.png`.
    @MainActor
    private func assertGuideFixture(_ fixture: String, campaignType: String) async throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let campaign = try #require(
            try CampaignModel.fromJson(json, designTokens: fixtureTokens(json), devicePlatform: "ios"),
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
        assertSurfaceGolden(
            ComponentTestHost.settledImage(of: showing.window),
            surface: campaignType,
            named: fixture,
            precision: 1.0,
            perceptualPrecision: 0.98
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
        let window = makeGuideWindow(device: .engageGolden)
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
        let window = ComponentTestHost.makeWindow(frame: CGRect(origin: .zero, size: size))

        let rootVC = ComponentTestHost.makeDeviceHost(
            device: device,
            scrimColor: nil,
            showHomeIndicator: false
        )
        ComponentTestHost.addGuideAnchors(to: rootVC.view, safeTop: device.safeArea.top)

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
}
}
