import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// A `degrade_survey_*` survey this build must show only in part, answered by a respondent. It arrives
/// in the `SurveyDegradationBundle` (`Tests/DigiaEngageTests/FixtureBehaviour/SurveyGuideSupport.swift`).
/// That the unreadable ones are dropped and reported is the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/SurveyDegradationTests.swift`.
///
/// Port of `flutter/core/test/fixture_behaviour/survey_degradation_test.dart`.
@Suite("Survey: degradation", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyDegradationTests {

    // Fails if: canvas_survey_config_parser.swift stops skipping a scene or node that is not an
    // object (`compactMap { SurveyParse.object($0) }`), dropping the whole survey instead.
    @Test("a survey with junk among its scenes and flow nodes is kept and runs on the entries that are readable")
    func partialScenesRun() async throws {
        let sdk = try await SurveyDegradationBundle.boot()
        defer { sdk.tearDown(); HealthSink.shared.resetForTest() }

        try await sdk.openSurvey(SurveyDegradationBundle.partialKey, firstText: "A question")
        try await sdk.tapExact("A")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the survey completes") { SDKInstance.shared.surveyOrchestrator.state == nil
            || !sdk.isShowing("A question") }

        #expect(try await sdk.questionsViewed(SurveyDegradationBundle.partialKey) == ["node_q"])
        let completed = try await sdk.only("Digia Experience Completed", of: SurveyDegradationBundle.partialKey)
        #expect(completed["answered_count"] as? Int == 1)
        let response = try #require(completed["response"] as? [String: Any])
        #expect(Array(response.keys) == ["node_q"])
        let answer = try #require(surveyAnswer(response, "node_q"))
        #expect(answer.values == ["o_a"])
        #expect(answer.noComment)
    }
}
}
