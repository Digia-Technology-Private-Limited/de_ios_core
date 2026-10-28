import Foundation
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension RenderedUITests {
/// Pixel goldens for every Test Kit survey fixture.
///
/// The arguments are read from `sdk_testing_fixtures/campaigns/survey/`, so a fixture added to the
/// Test Kit gets a golden with no code change (record it with
/// `RECORD_SNAPSHOTS=true ./run-tests.sh survey`). Each fixture is decoded by
/// `CampaignModel.fromJson`, started on the SDK's survey orchestrator, and drawn by the production
/// `SurveyRenderer` — the layer `DigiaHost` mounts — so each golden is the survey's first scene in
/// its dialog or bottom sheet.
@Suite("Test Kit survey fixture goldens", .serialized, .tags(.survey))
struct SurveyFixtureGoldenTests {

    @Test("matches the survey fixture golden", .tags(.golden), arguments: FixtureLoader.fixtureNames(campaignType: "survey"))
    @MainActor
    func testSurveyFixtureGolden(fixture: String) async throws {
        let json = try #require(
            FixtureLoader.loadFixture(campaignType: "survey", fileName: fixture),
            "Failed to load fixture survey/\(fixture).json"
        )
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)), "Fixture must decode to a campaign")
        let config = try #require(campaign.surveyConfig, "Fixture must decode to a survey")

        let orchestrator = SDKInstance.shared.surveyOrchestrator
        let started = orchestrator.start(
            payload: CEPTriggerPayload(cepCampaignId: "test_survey", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            config: config
        )
        try #require(started, "Survey orchestrator refused the fixture")

        let window = makeSurveyWindow()
        defer {
            // SDKInstance is process-wide; end the showing so the next fixture can start.
            orchestrator.dismiss()
            ComponentTestHost.cleanupOverlayWindow(window)
        }
        // The survey waits its authored delay plus a render buffer before it appears, in a
        // main-actor `Task.sleep`; awaiting (not spinning the run loop) lets that task resume.
        try await Task.sleep(nanoseconds: UInt64(config.timeDelayMs + 500) * 1_000_000)

        // Exact within the perceptual tolerance, as the nudge and floater fixture goldens.
        assertVisualGolden(
            matching: ComponentTestHost.settledImage(of: window),
            precision: 1.0,
            perceptualPrecision: 0.98,
            named: fixture,
            function: "testSurveyFixtureGolden"
        )
    }

    /// A key window with the survey layer over a plain host, as `DigiaHost` stacks them.
    ///
    /// Sized to the simulator's screen: the test bundle has no window scene, so the survey falls
    /// back to `UIScreen.main.bounds` for its window frame, and the two must agree.
    @MainActor
    private func makeSurveyWindow() -> UIWindow {
        let bounds = UIScreen.main.bounds
        let window = UIWindow(frame: bounds)

        let rootVC = UIViewController()
        rootVC.view.frame = bounds
        ComponentTestHost.addStripes(to: rootVC.view)
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
