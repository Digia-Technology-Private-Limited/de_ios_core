import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `survey_welcome_backdrop_stepback`: a welcome page, a required choice, two optional questions
/// and a thank-you page, in a dialog whose backdrop dismisses. The tests press Back, Next and the
/// backdrop as a respondent does and read what stays on screen and what the CEP and analytics are
/// told.
///
/// Port of `flutter/core/test/fixture_behaviour/survey_welcome_backdrop_test.dart`.
@Suite("Survey: welcome, backdrop and step back", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyWelcomeBackdropTests {

    private static let key = "test_survey_welcome_backdrop_stepback"
    private static let welcome = "Help Us Improve Digia"
    private static let q1 = "How often do you shop with us?"
    private static let q2 = "What should we improve? (optional)"
    private static let q3 = "Rate the app (optional)"
    private static let thanks = "Thank you for participating!"

    private func open() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.surveyGuideStart(["campaigns/survey/survey_welcome_backdrop_stepback.json"])
        let presentation = try await sdk.openSurvey(Self.key, firstText: Self.welcome)
        return (sdk, presentation)
    }

    private func openAtFirstQuestion() async throws -> (SdkHarness, CampaignPresentation) {
        let (sdk, presentation) = try await open()
        try await sdk.tapExact("Start Survey")
        try await sdk.waitUntil("the first question") { sdk.isShowing(Self.q1) }
        return (sdk, presentation)
    }

    /// A backdrop tap, once the dialog takes touches (it ignores the backdrop for its first
    /// 350 ms; `DialogContainer.armed`).
    private func tapBackdrop(_ sdk: SdkHarness) async throws {
        try await sdk.settle(0.4)
        try sdk.tapBackdrop()
    }

    // Fails if: SDKInstance.swift `markSurveyDismissed` stops reporting the renderer's
    // `abandonedAtItem` / `answeredCount`, or the dialog backdrop (survey_renderer.swift
    // `if armed && dialog.backdropDismissible { onDismiss() }`) stops dismissing.
    @Test("a backdrop tap on the first question closes the survey instead of returning to the welcome page")
    func backdropOnFirstQuestionCloses() async throws {
        let (sdk, presentation) = try await openAtFirstQuestion()
        defer { sdk.tearDown() }

        try await tapBackdrop(sdk)

        try await sdk.waitUntil("the survey is gone") { SDKInstance.shared.surveyOrchestrator.state == nil }
        #expect(!sdk.isShowing(Self.q1))
        #expect(!sdk.isShowing(Self.welcome))
        let dismissed = try await sdk.only("Digia Experience Dismissed", of: Self.key)
        #expect(dismissed["dismiss_reason"] as? String == "user_close")
        #expect(dismissed["abandoned_at_item"] as? Int == 1)
        #expect(dismissed["answered_count"] as? Int == 0)
        #expect(presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false))
    }

    // Fails if: canvas_survey_answer_validator.swift `guard answer?.isAnswered == true else {
    // return missingAnswerMessage(for: input) }` stops holding an unanswered required question.
    @Test("a required question holds the respondent until it is answered")
    func requiredHolds() async throws {
        let (sdk, _) = try await openAtFirstQuestion()
        defer { sdk.tearDown() }

        try await sdk.surveyNext()

        try await sdk.waitUntil("the refusal") { sdk.isShowing("Select an option") }
        #expect(sdk.isShowing(Self.q1))
        #expect(try await sdk.questionsViewed(Self.key) == ["node_q1"])
    }

    /// Flutter's dialog treats a backdrop tap as the system back: with an earlier question to
    /// return to, it steps back one question and dismisses nothing (`_handlePop`: `canGoBack` ->
    /// `back()`). iOS's `DialogContainer` (survey_renderer.swift) calls `onDismiss()` on every
    /// armed backdrop tap, so the survey closes from the second question.
    // Fails if: the iOS backdrop starts stepping back (the known issue then passes and
    // `withKnownIssue` fails, the cue to drop it).
    @Test("a backdrop tap with earlier questions steps back one question and dismisses nothing; the next tap on the first question abandons")
    func backdropStepsBack() async throws {
        let (sdk, presentation) = try await openAtFirstQuestion()
        defer { sdk.tearDown() }
        try await sdk.tapExact("Weekly")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the second question") { sdk.isShowing(Self.q2) }

        try await tapBackdrop(sdk)

        try await withKnownIssue("iOS closes a survey dialog on a backdrop tap instead of stepping back a question") {
            try await sdk.waitUntil("back on the first question", timeout: 1.5) { sdk.isShowing(Self.q1) }
            #expect(try await sdk.tracked("Digia Experience Dismissed", of: Self.key).isEmpty)
            #expect(presentation.outcome.settledValue == nil)
        }
        if SDKInstance.shared.surveyOrchestrator.state != nil {
            // Stepped back: the next tap on the first question abandons.
            try await tapBackdrop(sdk)
        }

        try await sdk.waitUntil("the survey is gone") { SDKInstance.shared.surveyOrchestrator.state == nil }
        #expect(!sdk.isShowing(Self.q1))
        let dismissed = try await sdk.only("Digia Experience Dismissed", of: Self.key)
        #expect(dismissed["dismiss_reason"] as? String == "user_close")
        #expect(dismissed["answered_count"] as? Int == 1)
        withKnownIssue("iOS abandons from the second question, not after stepping back to the first") {
            #expect(dismissed["abandoned_at_item"] as? Int == 1)
        }
        #expect(try await sdk.tracked("Digia Experience Completed", of: Self.key).isEmpty)
        #expect(presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false))
    }

    // Fails if: survey_renderer.swift `if armed && dialog.backdropDismissible { onDismiss() }`
    // stops dismissing from the welcome page, or `reportSurveyQuestionViewed` fires for it.
    @Test("a backdrop tap on the welcome page abandons with nothing answered")
    func backdropOnWelcomeAbandons() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }

        try await tapBackdrop(sdk)

        try await sdk.waitUntil("the survey is gone") { SDKInstance.shared.surveyOrchestrator.state == nil }
        #expect(!sdk.isShowing(Self.welcome))
        let dismissed = try await sdk.only("Digia Experience Dismissed", of: Self.key)
        #expect(dismissed["dismiss_reason"] as? String == "user_close")
        #expect(dismissed["answered_count"] as? Int == 0)
        #expect(try await sdk.tracked("Digia Question Viewed", of: Self.key).isEmpty,
                "the respondent never reached a question")
        #expect(presentation.outcome.settledValue == .dismissed(reason: .userClose, completed: false))
    }

    // Fails if: canvas_survey_renderer.swift `} else if !block.required {` in `primary()` stops
    // reporting a skip, or `reportCompletionIfResultIsNext` stops firing before the thank-you page.
    @Test("optional questions can be skipped, each is reported skipped, and the thank-you page completes with only what was answered")
    func optionalSkipsAndCompletes() async throws {
        let (sdk, presentation) = try await openAtFirstQuestion()
        defer { sdk.tearDown() }
        try await sdk.tapExact("Weekly")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the second question") { sdk.isShowing(Self.q2) }

        try await sdk.surveyNext()
        try await sdk.waitUntil("the third question") { sdk.isShowing(Self.q3) }
        try await sdk.surveyNext()
        try await sdk.waitUntil("the thank-you page") { sdk.isShowing(Self.thanks) }

        let skipped = try await sdk.tracked("Digia Question Skipped", of: Self.key)
            .compactMap { SdkHarness.props($0)["question_id"] as? String }
        #expect(skipped == ["node_q2", "node_q3"])
        let completed = try await sdk.only("Digia Experience Completed", of: Self.key)
        #expect(completed["answered_count"] as? Int == 1)
        let response = try #require(completed["response"] as? [String: Any])
        #expect(Array(response.keys) == ["node_q1"])
        let q1 = try #require(surveyAnswer(response, "node_q1"))
        #expect(q1.values == ["o_weekly"])
        #expect(q1.noComment)

        // The submission carries only the answered question.
        let submissions = try await sdk.submissions()
        #expect(submissions.count == 1)
        let payload = submissions.first?["payload"] as? [String: Any]
        let completion = payload?["completion"] as? [String: Any]
        #expect(completion?["answeredCount"] as? Int == 1)
        #expect(completion?["totalCount"] as? Int == 3)
        let responses = payload?["responses"] as? [[String: Any]] ?? []
        #expect(responses.map { $0["value"] as? String } == ["o_weekly"])

        try await sdk.tapExact("Finish")
        try await sdk.waitUntil("the CEP is told") { presentation.outcome.settledValue != nil }
        #expect(presentation.outcome.settledValue == .dismissed(reason: .completed, completed: true))
    }
}
}
