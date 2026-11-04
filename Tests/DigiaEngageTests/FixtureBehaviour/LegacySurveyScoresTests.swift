import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A legacy block-based survey whose timer runs out with nobody answering: `legacy_survey/
/// legacy_survey_scores_sheet`, with a two-second time limit set in the test. Answering it is the
/// sample app's `LegacySurveyScoresTests`.
///
/// iOS only: Flutter no longer reads this shape.
@Suite("Legacy survey: score blocks in a sheet, untouched", .serialized,
       .tags(.integration, .behaviour, .survey))
@MainActor
struct LegacySurveyScoresTests {

    private static let key = "test_legacy_survey_scores"
    private static let intro = "Rate your last order"

    private func open(_ campaign: [String: Any]? = nil) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([campaign ?? fixture("legacy_survey/legacy_survey_scores_sheet")])
        let presentation = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the intro", timeout: 4) { sdk.isShowing(Self.intro) }
        return (sdk, presentation)
    }

    // Fails if `SurveyBody.startTimer` stops closing the survey at zero (`if remainingSecs == 0 {
    // onClose() }`).
    @Test("a timer that runs out closes the survey")
    func timerRunsOut() async throws {
        let campaign = try legacyFixture("legacy_survey/legacy_survey_scores_sheet") { config in
            var settings = config["settings"] as? [String: Any] ?? [:]
            settings["surveyTimer"] = ["timer": true, "timeLimit": 2, "pauseOnNonTimerBlock": false]
            config["settings"] = settings
        }
        let (sdk, presentation) = try await open(campaign)
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the timer closed the survey", timeout: 5) {
            presentation.outcome.settledValue != nil
        }
        #expect(presentation.dismissReason == .userClose)
        #expect(presentation.legacyCompleted == false)
        #expect(try await sdk.legacySubmissions().isEmpty)
    }
}
}
