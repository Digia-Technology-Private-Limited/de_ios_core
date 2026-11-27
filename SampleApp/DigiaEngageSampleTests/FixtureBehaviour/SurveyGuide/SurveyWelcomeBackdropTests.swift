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
