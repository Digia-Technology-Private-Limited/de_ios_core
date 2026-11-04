import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// The canvas survey renderer's timer host, with nobody answering: it counts down and closes the
/// survey, or shows nothing when the survey has no time limit. Each test opens a copy of
/// `survey/survey_core_blocks` with one setting or host changed. The renderer's other branches are
/// the sample app's `SurveyCanvasRendererTests`.
///
/// No Flutter unit test covers these one by one; the Flutter reference is the golden
/// `flutter/core/test/visual_regression/survey_golden_test.dart`.
@Suite("Canvas survey: renderer timer", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCanvasRendererTests {

    private static let single = "Which do you use most?"

    private func open(_ campaign: SurveyCanvasCampaign, firstText: String = single) async throws
        -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        let presentation = try await sdk.surveyCanvasOpen(campaign.key, firstText: firstText)
        return (sdk, presentation)
    }

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
