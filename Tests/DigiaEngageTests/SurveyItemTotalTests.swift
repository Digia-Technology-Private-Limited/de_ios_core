import Foundation
import Testing
@testable import DigiaEngage

/// Event `item_total` counts every graph node, including content chrome
/// (text-media / result pages) — not just prompts, whose count stays the
/// submission's `totalCount` (testkit `SURVEY-COVERAGE-PLAN.md` B12; Flutter
/// counts `config.nodes.length`).
@Suite("Survey event item total")
struct SurveyItemTotalTests {

    @Test("a single-question survey with a thanks page totals two items")
    func stackedCtaTotalsTwo() throws {
        let json = try fixture("survey/survey_stacked_cta")
        let campaign = try #require(try CampaignModel.fromJson(json, designTokens: fixtureTokens(json)))
        let survey = try #require(campaign.surveyConfig)
        // Fails if: SurveyConfigModel `itemTotal` filters out content/result
        // nodes (the prompts-only `questionCount`; Android tracks the same
        // gap under F21).
        #expect(survey.itemTotal == survey.nodes.count)
        #expect(survey.itemTotal == 2)
    }
}
