import Foundation
import SDWebImage
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for the pre-canvas campaign shapes iOS still renders: legacy nudges (a
/// `templateConfig.layout` column tree, no `layoutMode`) and legacy block-based surveys (no
/// `layoutMode: canvas`). Their fixtures live in `sdk_testing_fixtures/campaigns/legacy_nudge/`,
/// `classic_nudge/` and `legacy_survey/`.
///
/// One golden per fixture, of its first screen. A fixture added to either directory gets a golden
/// with no code change (record it with `RECORD_SNAPSHOTS=true ./run-tests.sh survey`).
@Suite("Legacy fixture goldens", .serialized, .tags(.nudge, .survey))
struct LegacyFixtureGoldenTests {

    // MARK: - Legacy nudges

    /// Decoded by `NudgeConfig.fromJson` (the legacy branch: `NudgeParser`) and drawn by the
    /// production `NudgeOverlayView`, whose dialog and sheet put the column through
    /// `NudgeColumnContent` / `NudgeNodeRenderer`. Variables resolve to their authored fallbacks,
    /// as they do when the CEP sends none.
    @Test("matches the legacy nudge fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "legacy_nudge"))
    @MainActor
    func testLegacyNudgeFixtureGolden(fixture: String) async throws {
        try await assertColumnTreeNudge(fixture, campaignType: "legacy_nudge", function: "testLegacyNudgeFixtureGolden")
    }

    /// One dialog per classic node widget (text, buttons, dividers, gaps, progress, images, carousel),
    /// as Android's `ClassicNudgeGoldenTest`; same shape and path as the legacy nudges.
    @Test("matches the classic nudge fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "classic_nudge"))
    @MainActor
    func testClassicNudgeFixtureGolden(fixture: String) async throws {
        try await assertColumnTreeNudge(fixture, campaignType: "classic_nudge", function: "testClassicNudgeFixtureGolden")
    }

    @MainActor
    private func assertColumnTreeNudge(_ fixture: String, campaignType: String, function: StaticString) async throws {
        await clearImageCaches()
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: campaignType, fileName: fixture),
            "Failed to load fixture \(campaignType)/\(fixture).json"
        )
        let templateConfig = try #require(json["templateConfig"] as? [String: Any], "Missing templateConfig")
        let config = try #require(
            try NudgeConfig.fromJson(templateConfig, designTokens: fixtureTokens(json)),
            "Fixture must decode to a nudge")
        try #require(config.canvas == nil, "A legacy fixture must take the column-tree path")

        let window = ComponentTestHost.makeRealOverlayWindow(
            nudgeConfig: config,
            device: .engageGolden,
            style: .striped
        )
        defer { ComponentTestHost.cleanupOverlayWindow(window) }
        // The helper presents without variables; present again with the fixture's fallbacks so
        // `{{first_name}}` reads as a user would see it.
        let controller = SDKInstance.shared.controller
        controller.forceNudgeDismiss()
        ComponentTestHost.drainRunLoop(for: 0.3)
        controller.showNudge(DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(
                cepCampaignId: "test_\(campaignType)_\(fixture)", campaignKey: keyOf(json), cepMetadata: [:]),
            variables: buildVariableContext(schemas: config.variableSchemas, cepVars: nil)
        ))
        // Awaited, not a run-loop spin: the image, carousel and Lottie loads finish in main-actor
        // tasks, which only resume while the test is suspended.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: function
        )
    }

    // MARK: - Legacy surveys

    /// Decoded by `CampaignModel.fromJson` (the `SurveyConfigModel.from` branch), started on the
    /// SDK's survey orchestrator and drawn by the production `SurveyRenderer`, as
    /// `SurveyFixtureGoldenTests` does for the canvas surveys.
    @Test("matches the legacy survey fixture golden", .tags(.golden),
          arguments: FixtureLoader.fixtureNames(campaignType: "legacy_survey"))
    @MainActor
    func testLegacySurveyFixtureGolden(fixture: String) async throws {
        await clearImageCaches()
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: "legacy_survey", fileName: fixture),
            "Failed to load fixture legacy_survey/\(fixture).json"
        )
        let campaign = try #require(
            try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)),
            "Fixture must decode to a campaign")
        let config = try #require(campaign.surveyConfig, "Fixture must decode to a survey")
        try #require(config.canvasSurvey == nil, "A legacy fixture must take the block-based path")

        let orchestrator = SDKInstance.shared.surveyOrchestrator
        let started = orchestrator.start(
            payload: CEPTriggerPayload(
                cepCampaignId: "test_legacy_survey", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            config: config
        )
        try #require(started, "Survey orchestrator refused the fixture")

        let window = Self.makeSurveyWindow()
        defer {
            orchestrator.dismiss()
            ComponentTestHost.cleanupOverlayWindow(window)
        }
        try await Task.sleep(nanoseconds: UInt64(config.timeDelayMs + 800) * 1_000_000)

        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: "testLegacySurveyFixtureGolden"
        )
    }

    /// `WebImage` draws a memory-cache hit and an asynchronous load through different decode paths,
    /// and other suites load the same Test Kit images first; start every golden from empty caches
    /// (as `PipFixtureGoldenTests` does) so a fixture renders the same in a full run as alone.
    @MainActor
    private func clearImageCaches() async {
        SDImageCache.shared.clearMemory()
        await withCheckedContinuation { done in SDImageCache.shared.clearDisk { done.resume() } }
    }

    /// A key window with the survey layer over a plain host, as `DigiaHost` stacks them. Sized to
    /// the simulator's screen, which the survey falls back to for its window frame.
    @MainActor
    private static func makeSurveyWindow() -> UIWindow {
        let bounds = UIScreen.main.bounds
        let window = UIWindow(frame: bounds)
        let rootVC = UIViewController()
        rootVC.view.frame = bounds
        // Not white: the survey's light surfaces would blend into a white host.
        rootVC.view.backgroundColor = UIColor(red: 0x26 / 255, green: 0xA6 / 255, blue: 0x9A / 255, alpha: 1)
        let overlayVC = UIHostingController(
            rootView: SurveyRenderer(orchestrator: SDKInstance.shared.surveyOrchestrator)
        )
        overlayVC.view.frame = bounds
        overlayVC.view.backgroundColor = .clear
        rootVC.addChild(overlayVC)
        rootVC.view.addSubview(overlayVC.view)
        overlayVC.didMove(toParent: rootVC)
        window.rootViewController = rootVC
        window.makeKeyAndVisible()
        return window
    }
}
}
