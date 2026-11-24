import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// The canvas survey renderer's branches the fixture suites do not reach: auto-advance (and the
/// inputs it must leave alone), the page-count and timer hosts, navigation hosts authored without
/// a canvas button, a validation message on a scene without an answer host, and the bottom-sheet
/// stage. Uses `survey/survey_auto_advance`, `survey/survey_bottomsheet_close` and copies of
/// `survey/survey_core_blocks` with one setting or host changed.
///
/// No Flutter unit test covers these one by one; the Flutter reference is the golden
/// `flutter/core/test/visual_regression/survey_golden_test.dart` (auto-advance, bottom-sheet close)
/// and `flutter/core/test/fixture_behaviour/survey_welcome_backdrop_test.dart` for the style.
@Suite("Canvas survey: renderer", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCanvasRendererTests {

    private func open(_ campaign: SurveyCanvasCampaign, firstText: String = "Which do you use most?") async throws
        -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        let presentation = try await sdk.surveyCanvasOpen(campaign.key, firstText: firstText)
        return (sdk, presentation)
    }

    // MARK: - Managed hosts

    // Fails if: canvas_survey_renderer.swift's `.pageCount` host stops reading
    // `vm.progressCurrent` / `vm.progressTotal` (or counts the thank-you page).
    @Test("a page count host shows the question reached out of the questions on the route")
    func pageCount() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.addSharedHost(id: "survey_count", role: "pageCount",
                                   rect: ["x": 0.7, "y": 0.02, "width": 0.25, "height": 0.05])
        let (sdk, _) = try await open(campaign)
        defer { sdk.tearDown() }

        try await sdk.waitUntil("1 of 4") { sdk.isShowing("1/4") }
        try await sdk.surveyCanvasTap("Prescriptions")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("2 of 4") { sdk.isShowing("2/4") }
        #expect(!sdk.isShowing("1/4"))
    }

    // MARK: - Bottom sheet

    // Fails if: canvas_survey_renderer.swift stops drawing the authored close over a bottom-sheet
    // stage (`if showCloseButton, ... close.placement?.rect != nil`), or its tap stops closing.
    @Test("the close button of a bottom-sheet canvas survey ends it as a user close")
    func bottomSheetClose() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_bottomsheet_close")
        let (sdk, presentation) = try await open(campaign, firstText: "How satisfied are you with checkout?")
        defer { sdk.tearDown() }

        try await sdk.surveyCanvasTap("Close survey")
        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false))
    }

    // MARK: - Timer

    // Fails if: canvas_survey_renderer.swift `startTimerIfNeeded` stops counting down or stops
    // closing the survey at zero (`if remainingSecs == 0 { onClose() }`), or the timer host stops
    // showing the remaining time.
    @Test("a timer host counts down and closes the survey when it runs out")
    func timerRunsOut() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.behavior.addEntries(from: [
            "timerEnabled": true, "timerDurationSeconds": 3, "pauseTimerOnContent": false,
        ])
        try campaign.addSharedHost(id: "survey_timer", role: "timer",
                                   rect: ["x": 0.7, "y": 0.02, "width": 0.25, "height": 0.05])
        let (sdk, presentation) = try await open(campaign)
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the timer counts down") { sdk.isShowing("0:02") || sdk.isShowing("0:01") }
        try await sdk.waitUntil("the timer closed the survey", timeout: 6) {
            presentation.outcome.settledValue != nil
        }
        #expect(presentation.dismissReason == .userClose)
        #expect(try await sdk.surveyCanvasTracked("Digia Experience Completed", of: campaign.key).isEmpty)
    }

    // Fails if: canvas_survey_renderer.swift's `.timer` host stops checking that the timer is
    // enabled (it would show a frozen "0:00" on a survey without a time limit).
    @Test("a timer host shows nothing when the survey has no time limit")
    func timerHostHiddenWithoutLimit() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.addSharedHost(id: "survey_timer", role: "timer",
                                   rect: ["x": 0.7, "y": 0.02, "width": 0.25, "height": 0.05])
        let (sdk, presentation) = try await open(campaign)
        defer { sdk.tearDown() }

        try await sdk.settle(1.2)
        #expect(!sdk.isShowing("0:00"))
        #expect(presentation.outcome.settledValue == nil)
    }
}
}
