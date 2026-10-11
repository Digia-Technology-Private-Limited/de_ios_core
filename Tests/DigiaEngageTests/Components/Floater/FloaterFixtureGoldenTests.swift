import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit story-floater fixture.
///
/// The arguments are read from `testkit/campaigns/floater/fixtures/`, so a fixture added to the
/// Test Kit is covered with no code change (record it with
/// `RECORD_SNAPSHOTS=true ./run-tests.sh floater`). Each fixture is decoded by
/// `CampaignModel.fromJson`, started on the SDK's story-floater orchestrator, and drawn by the
/// production `FloaterStoryOverlayView` — the layer `DigiaHost` mounts — over a host screen.
@Suite("Test Kit floater fixture goldens", .serialized, .tags(.floater))
struct FloaterFixtureGoldenTests {

    /// Fixtures whose `story.pages` is empty. The SDK drops a story floater with no story to open,
    /// so there is nothing to draw; each is asserted to stay dropped, and fails once its fixture is
    /// fixed so it can get a golden instead.
    private static let dropped: Set<String> = [
        "floater-action-url",
        "floater-badge-counter",
    ]

    private static let fixtures = FixtureLoader.fixtureNames(campaignType: "floater")

    @Test("matches the floater fixture golden", .tags(.golden), arguments: fixtures.filter { !dropped.contains($0) })
    @MainActor
    func testFloaterFixtureGolden(fixture: String) async throws {
        let campaign = try #require(
            loadCampaign(fixture, holdingStoryPages: true),
            "Fixture must decode to a campaign"
        )
        try #require(campaign.floaterStoryConfig != nil, "Fixture must decode to a story floater")
        // The canvas loads images through SDWebImage; serve the Test Kit's from memory so the
        // golden has the real pixels rather than whatever the async load had reached.
        ComponentTestHost.prewarmAssetImage(named: "strawberry.jpg")

        let orchestrator = SDKInstance.shared.floaterStoryOrchestrator!
        let started = orchestrator.start(
            campaign,
            payload: CEPTriggerPayload(cepCampaignId: "test_floater", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            screenName: nil
        )
        try #require(started, "Floater orchestrator refused the fixture: \(orchestrator.lastStartFailureReason ?? "unknown")")

        // The test bundle has no host app, so the floater cannot look up the device's window scene;
        // pin the screen and its notch / home-indicator insets to the golden's device instead.
        let device = ViewImageConfig.iPhone17ProMax
        let insets = device.safeArea
        activeFloaterWindowGeometryOverride = (
            CGRect(origin: .zero, size: device.size!),
            EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        )
        let window = makeFloaterWindow(device: device)
        defer {
            activeFloaterWindowGeometryOverride = nil
            // SDKInstance is process-wide; end the showing so the next fixture can start.
            orchestrator.dismiss(.hostTeardown)
            ComponentTestHost.cleanupOverlayWindow(window)
        }

        // Exact within the perceptual tolerance, as the nudge fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: "testFloaterFixtureGolden"
        )

        // What a tap on the window does, minus the click analytics. The hero runs as a SwiftUI
        // animation and the story chrome is revealed by a main-queue callback after it; awaiting
        // (not spinning the run loop) lets the viewer's main-actor work run as well.
        orchestrator.openStory()
        try await Task.sleep(nanoseconds: 800_000_000)
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: "\(fixture)-expanded",
            function: "testFloaterFixtureGolden"
        )
    }

    @Test("drops a story floater with no story to open", .tags(.contract), arguments: fixtures.filter { dropped.contains($0) })
    func testFloaterFixtureDropped(fixture: String) {
        #expect(
            loadCampaign(fixture) == nil,
            "\(fixture) now decodes; remove it from `dropped` so it gets a golden"
        )
    }

    /// With `holdingStoryPages`, every story page lasts a day: the viewer's progress bar is driven by
    /// a wall-clock timer, so at the authored length it would be at a different spot in every run.
    private func loadCampaign(_ fixture: String, holdingStoryPages: Bool = false) -> CampaignModel? {
        guard var json = FixtureLoader.loadFixture(campaignType: "floater", fileName: fixture) else { return nil }
        if holdingStoryPages,
           var template = json["templateConfig"] as? [String: Any],
           var story = template["story"] as? [String: Any],
           let pages = story["pages"] as? [[String: Any]]
        {
            story["pages"] = pages.map { page in page.merging(["durationSeconds": 86_400]) { $1 } }
            template["story"] = story
            json["templateConfig"] = template
        }
        return CampaignModel.fromJson(json)
    }

    /// A key window with the floater layer over a plain host, as `DigiaHost` stacks them.
    @MainActor
    private func makeFloaterWindow(device: ViewImageConfig) -> UIWindow {
        let size = device.size!
        let window =
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(origin: .zero, size: size))
        window.frame = CGRect(origin: .zero, size: size)

        let rootVC = ComponentTestHost.makeDeviceHost(
            device: device,
            // Not white: a canvas without a background draws a white window.
            style: .solid(UIColor(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255, alpha: 1)),
            scrimColor: nil,
            showHomeIndicator: false
        )
        let overlayVC = UIHostingController(rootView: FloaterStoryOverlayView())
        overlayVC.view.frame = CGRect(origin: .zero, size: size)
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)

        window.rootViewController = rootVC
        window.makeKeyAndVisible()

        ComponentTestHost.drainRunLoop(for: 0.2)
        // A prewarmed image is a synchronous cache hit, which `WebImage` publishes from inside the
        // view update that requested it, and SwiftUI drops that update. Flipping the trait
        // environment re-evaluates the image renderer, which then draws it (as
        // `ComponentTestHost.makeCanvasSlotHost` does).
        overlayVC.overrideUserInterfaceStyle = .dark
        ComponentTestHost.drainRunLoop(for: 0.4)
        overlayVC.overrideUserInterfaceStyle = .light
        return window
    }
}
}
