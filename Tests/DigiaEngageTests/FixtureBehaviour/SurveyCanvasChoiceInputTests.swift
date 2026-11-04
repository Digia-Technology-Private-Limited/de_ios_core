import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// How the choice answer input lays out an uneven `grid`, read before anyone answers. The test opens
/// a copy of `survey/survey_core_blocks` with the first scene's answer host changed. Answering the
/// choice inputs is the sample app's `SurveyCanvasChoiceInputTests`.
///
/// No Flutter unit test covers these inputs one by one; the Flutter reference is the golden
/// `flutter/core/test/visual_regression/survey_golden_test.dart`.
@Suite("Canvas survey: choice input layout", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCanvasChoiceInputTests {

    private static let single = "Which do you use most?"

    private func open(_ campaign: SurveyCanvasCampaign) async throws -> SdkHarness {
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        try await sdk.surveyCanvasOpen(campaign.key, firstText: Self.single)
        return sdk
    }

    // Fails if: canvas_survey_answer_inputs.swift's grid stops filling a short last row with an
    // empty cell (`Color.clear` for `column >= row.count`): the last option then stretches across
    // both columns.
    @Test("a grid keeps the last option in its column when the last row is short")
    func gridShortLastRow() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.answerHostProps("scene_single")["style"] = ["layout": "grid", "columns": 2]
        let sdk = try await open(campaign)
        defer { sdk.tearDown() }

        let first = try #require(sdk.surveyCanvasFrames("Prescriptions").first)
        let second = try #require(sdk.surveyCanvasFrames("Wellness").first)
        let third = try #require(sdk.surveyCanvasFrames("Devices").first)
        #expect(abs(first.midY - second.midY) < 2, "the first row holds two options")
        #expect(third.minY > first.maxY, "the third option starts a second row")
        #expect(abs(third.minX - first.minX) < 2)
        #expect(third.maxX < second.minX, "the third option stays inside the first column: \(third)")
    }
}
}
