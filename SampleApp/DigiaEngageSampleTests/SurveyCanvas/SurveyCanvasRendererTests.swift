import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// The canvas survey renderer's branches the fixture suites do not reach: auto-advance (and the
/// inputs it must leave alone), the page-count host (the timer host is the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/SurveyCanvasRendererTests.swift`), navigation hosts authored without
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

    private static let single = "Which do you use most?"
    private static let multi = "What should we improve?"
    private static let rating = "Rate your last order"
    private static let text = "Anything else?"

    private func open(_ campaign: SurveyCanvasCampaign, firstText: String = single) async throws
        -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        let presentation = try await sdk.surveyCanvasOpen(campaign.key, firstText: firstText)
        return (sdk, presentation)
    }

    // MARK: - Auto-advance

    // Fails if: canvas_survey_renderer.swift `scheduleAutoAdvanceIfNeeded` stops advancing
    // (`vm.advance()`), or stops reporting the answer and the completion on the way.
    @Test("with auto-advance, choosing an option moves on by itself, reporting the answer once")
    func autoAdvanceMovesOn() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_auto_advance")
        let (sdk, _) = try await open(campaign, firstText: "Select your primary interest")
        defer { sdk.tearDown() }

        try await sdk.surveyCanvasTap("Wellness")
        try await sdk.waitUntil("the result page, without Next") { sdk.isShowing("Great choice!") }

        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_auto_q1")
        #expect(answers == [["o_wellness"]])
        #expect(try await sdk.surveyCanvasTracked("Digia Experience Completed", of: campaign.key, atLeast: 1).count == 1)
    }

    // Fails if: canvas_survey_answer_validator.swift `autoAdvanceEligible` lets a multi select
    // advance (the first chosen topic would carry the respondent away), or a scale stops advancing.
    @Test("auto-advance waits for Next on a multi select, and moves on from a rating")
    func autoAdvanceSkipsMultiSelect() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.behavior["autoAdvance"] = true
        let (sdk, _) = try await open(campaign)
        defer { sdk.tearDown() }

        try await sdk.surveyCanvasTap("Prescriptions")
        try await sdk.waitUntil("the multi select, without Next") { sdk.isShowing(Self.multi) }

        try await sdk.surveyCanvasTap("Search")
        try await sdk.settle(0.8)
        #expect(sdk.isShowing(Self.multi))
        #expect(!sdk.isShowing(Self.rating))

        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }
        try await sdk.surveyCanvasTap("4")
        try await sdk.waitUntil("the text question, without Next") { sdk.isShowing(Self.text) }
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

    // Fails if: canvas_survey_renderer.swift `CanvasSurveyButtonHost` stops drawing its own button
    // when the host has no canvas `button` (or stops falling back to "Next" for an empty label),
    // or the back host stops taking its authored label.
    @Test("navigation hosts without a canvas button draw their own, labelled and working")
    func plainNavigationButtons() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.sharedHostProps("survey_primary").removeObject(forKey: "button")
        let back = try campaign.sharedHostProps("survey_back")
        back.removeObject(forKey: "button")
        back["label"] = "Previous"
        let (sdk, _) = try await open(campaign)
        defer { sdk.tearDown() }

        // Unanswered, Next still answers the tap: with why it cannot go on.
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the empty answer is refused") { sdk.isShowing("Select an option") }
        #expect(sdk.isShowing(Self.single))

        try await sdk.surveyCanvasTap("Wellness")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the multi select on screen") { sdk.isShowing(Self.multi) }

        try await sdk.surveyCanvasTap("Previous")
        try await sdk.waitUntil("back on the first question") { sdk.isShowing(Self.single) }
        #expect(!sdk.isShowing(Self.multi))
    }

    // Fails if: canvas_survey_renderer.swift `validationErrorRect` stops placing the message at
    // the foot of the stage when the scene has no answer host (it would then show nothing, and
    // Next would silently do nothing).
    @Test("a required question whose answer host is missing still says why Next does nothing")
    func validationWithoutAnswerHost() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.removeAnswerHost("scene_single")
        let (sdk, _) = try await open(campaign)
        defer { sdk.tearDown() }

        #expect(!sdk.isShowing("Prescriptions"))
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the refusal is shown") { sdk.isShowing("Select an option") }
        #expect(sdk.isShowing(Self.single))
    }

    // MARK: - Bottom sheet

    // Fails if: canvas_survey_renderer.swift's stage stops laying out outside a dialog (the
    // `GeometryReader` branch a bottom sheet takes), or its NPS stops answering.
    @Test("a canvas survey in a bottom sheet is answered and completes")
    func bottomSheetCompletes() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_bottomsheet_close")
        let (sdk, _) = try await open(campaign, firstText: "How satisfied are you with checkout?")
        defer { sdk.tearDown() }

        try await sdk.surveyCanvasTap("9")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the thank-you page") { sdk.isShowing("Thank you!") }

        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_bs_q")
        #expect(answers == [["9"]])
        #expect(try await sdk.surveyCanvasTracked("Digia Experience Completed", of: campaign.key, atLeast: 1).count == 1)
    }

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
}
}
