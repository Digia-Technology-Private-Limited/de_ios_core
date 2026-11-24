// tags: widget survey campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// Every way a survey ends and the exact chain it sends: questions viewed, answered or skipped, Completed
/// only at its authored end, and one Clicked — welcome Start, or the first question's CTA when there is no
/// welcome screen, which stays Digia only. The cases that need a real touch; the rest run in the package, in
/// `Tests/DigiaEngageTests/CampaignBehaviour/SurveyCampaignBehaviourTests.swift`. Real touches through `SdkHarness`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/survey_campaign_behaviour_test.dart`. Its system-back case has
/// no iOS counterpart.
@MainActor
@Suite("Survey campaign behaviour: real touches", .serialized, .tags(.integration, .survey, .analytics))
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

    // MARK: - Closed

    @Test("answered to the end: completed, then dismissed as completed")
    func answeredToTheEnd() async throws {
        let key = "test_survey_stacked_cta"
        let sdk = try await start([survey("survey_stacked_cta")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Option Alpha")

        try await sdk.tap(label: "Option Alpha")
        try await sdk.tap(label: "Continue to Results")
        try await show(sdk, "All Done!")
        try await sdk.tap(id: "btn_scene_stacked_done")  // "Close Survey"
        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("All Done!") }

        let events = await sdk.sent(key)
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.questionViewed,
                // No welcome screen: the first question's CTA is the one Clicked, Digia only.
                Chain.clicked,
                Chain.questionAnswered, Chain.completed, Chain.dismissed,
            ],
            reason: .completed, cepClicks: 0)
        #expect(propsOf(events, Chain.completed)["answered_count"] as? Int == 1)
    }

    @Test("optional question skipped: skipped, then completed")
    func optionalQuestionSkipped() async throws {
        let key = "test_survey_optional_skip"
        let sdk = try await start([survey("survey_optional_skip")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Skip / Next")

        try await sdk.tap(label: "Skip / Next")
        try await show(sdk, "Thank you!")
        try await sdk.tap(id: "btn_scene_opt_done")  // "Done"
        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("Thank you!") }

        let events = await sdk.sent(key)
        // A skip is not an answer, so it is not the survey's Clicked.
        expectChain(
            events, d,
            names: [
                Chain.triggered, Chain.viewed, Chain.questionViewed, Chain.questionSkipped, Chain.completed,
                Chain.dismissed,
            ],
            reason: .completed)
        #expect(propsOf(events, Chain.completed)["answered_count"] as? Int == 0)
    }
}
