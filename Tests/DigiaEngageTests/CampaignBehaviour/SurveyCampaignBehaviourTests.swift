// tags: widget survey campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Every way a survey ends and the exact chain it sends: questions viewed, answered or skipped, Completed
/// only at its authored end, and one Clicked — welcome Start, or the first question's CTA when there is no
/// welcome screen, which stays Digia only. The cases that need a real touch run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/SurveyCampaignBehaviourTests.swift`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/survey_campaign_behaviour_test.dart`. Its system-back case has
/// no iOS counterpart.
@MainActor
@Suite("Survey campaign behaviour", .serialized, .tags(.integration, .survey, .analytics))
struct SurveyCampaignBehaviourTests {
    private func survey(_ name: String) -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/survey/\(name).json")
    }

    private func start(_ campaigns: [WorkspaceFixtures.Campaign]) async throws -> SdkHarness {
        try await SdkHarness.startChain(campaigns) { Text("App home") }
    }

    /// The renderer presents a survey after a short delay, on a timer.
    private func show(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
        try await sdk.settle(0.4)
    }

    // MARK: - Dropped

    @Test("survey: a nudge already up: surface_busy")
    func nudgeAlreadyUp() async throws {
        let key = "test_survey_stacked_cta"
        let sdk = try await start([
            WorkspaceFixtures.campaign("campaigns/nudge_dialog/nudge_dialog.json"), survey("survey_stacked_cta"),
        ])
        defer { sdk.tearDown() }
        _ = try sdk.deliverChain("test_nudge_dialog")
        try await show(sdk, "Dialog Test Nudge")

        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.2)
        #expect(!sdk.isShowing("Option Alpha"))

        expectDropped(await sdk.sent(key), d, .surfaceBusy)
    }

    @Test("survey: CEP cancel before it shows: cancelled")
    func cepCancelBeforeShowing() async throws {
        let key = "test_survey_stacked_cta"
        let campaign = survey("survey_stacked_cta")
        let sdk = try await start([campaign])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        d.presentation.cancel()
        try await sdk.settle(1.2)
        #expect(!sdk.isShowing("Option Alpha"))

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil,
            extras: ["cancel_cause": "cep_cancel"])
    }

    @Test("survey: off its target screen: screen_not_targeted")
    func offItsTargetScreen() async throws {
        let key = "test_survey_backdrop_locked"
        let campaign = survey("survey_backdrop_locked")
        let sdk = try await start([campaign])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.2)
        #expect(!sdk.isShowing("Option A"))

        expectDroppedWire(
            await sdk.sent(key), d, .screenNotTargeted, campaign, screen: "search",
            extras: ["target_screens": ["home", "brands"]],
            detail: "currentScreen=search targetScreenNames=[\"home\", \"brands\"]")
    }
}
}
