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

    /// The scrim above the sheet.
    private func tapScrim(_ sdk: SdkHarness) async throws { try await sdk.touch(CGPoint(x: 24, y: 120)) }

    // MARK: - Closed

    @Test("backdrop tap unanswered: dismissed as user_close")
    func backdropTapUnanswered() async throws {
        let key = "test_survey_stacked_cta"
        let sdk = try await start([survey("survey_stacked_cta")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Option Alpha")

        try await tapScrim(sdk)
        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("Option Alpha") }

        let events = await sdk.sent(key)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.questionViewed, Chain.dismissed],
            reason: .userClose)
        #expect(propsOf(events, Chain.dismissed)["answered_count"] as? Int == 0)
    }

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

    @Test("welcome Start: the one click the CEP sees")
    func welcomeStart() async throws {
        let key = "test_survey_welcome"
        let sdk = try await start([survey("survey_welcome_intro")])
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Start Survey")

        try await sdk.tap(id: "btn_start")  // "Start Survey"
        try await show(sdk, "Daily")
        try await tapScrim(sdk)
        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("Daily") }

        let events = await sdk.sent(key)
        expectChain(
            events, d, names: [Chain.triggered, Chain.viewed, Chain.clicked, Chain.questionViewed, Chain.dismissed],
            reason: .userClose)
        #expect(propsOf(events, Chain.clicked)["element_id"] as? String == "welcome_start")
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

    @Test("a locked backdrop: a scrim tap ends nothing, sends nothing")
    func lockedBackdrop() async throws {
        let key = "test_survey_backdrop_locked"
        let sdk = try await start([survey("survey_backdrop_locked")])
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")  // the fixture targets home
        let d = try sdk.deliverChain(key)
        try await show(sdk, "Option A")

        try await tapScrim(sdk)
        #expect(sdk.isShowing("Option A"))

        #expect(names(await sdk.sent(key)) == [Chain.triggered, Chain.viewed, Chain.questionViewed])
        #expect(d.timeline == ["displayed"], "shown, still holding the CEP, not ended")
    }

    // MARK: - Dropped

    @Test("survey: over its cap: frequency_capped, and the first chain intact")
    func overItsCap() async throws {
        let key = "test_survey_stacked_cta"
        let campaign = survey("survey_stacked_cta").cappedAtOne()
        let sdk = try await start([campaign])
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain(key)
        try await show(sdk, "Option Alpha")
        try await tapScrim(sdk)
        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("Option Alpha") }

        let second = try sdk.deliverChain(key)
        try await sdk.settle(1.2)
        #expect(!sdk.isShowing("Option Alpha"))

        let events = await sdk.sent(key)
        expectChain(
            eventsOf(first, in: events), first,
            names: [Chain.triggered, Chain.viewed, Chain.questionViewed, Chain.dismissed], reason: .userClose)
        expectDroppedWire(
            eventsOf(second, in: events), second, .frequencyCapped, campaign, screen: nil,
            extras: ["cap_rule": "max_total", "cap_limit": 1])
    }
}
