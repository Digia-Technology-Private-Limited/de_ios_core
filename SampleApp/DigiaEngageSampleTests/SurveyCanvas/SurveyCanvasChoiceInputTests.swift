import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// The choice answer input's branches the fixture suites do not reach: taking back a multi-select
/// choice, a cap of one, the `row` layout, an uneven `grid` layout, and the `upvote` kind. Each test
/// answers a copy of `survey/survey_core_blocks` (single select, optional multi select, rating,
/// text, thank-you page) with one scene's input or answer host changed, by real touches.
///
/// No Flutter unit test covers these inputs one by one; the Flutter reference is the golden
/// `flutter/core/test/visual_regression/survey_golden_test.dart` plus
/// `flutter/core/test/fixture_behaviour/survey_validation_rules_test.dart` for the style.
@Suite("Canvas survey: choice inputs", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCanvasChoiceInputTests {

    private static let single = "Which do you use most?"
    private static let multi = "What should we improve?"
    private static let rating = "Rate your last order"

    private func open(_ campaign: SurveyCanvasCampaign) async throws -> SdkHarness {
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        try await sdk.surveyCanvasOpen(campaign.key, firstText: Self.single)
        return sdk
    }

    /// Answers the first question and lands on the multi select.
    private func reachMulti(_ sdk: SdkHarness) async throws {
        try await sdk.surveyCanvasTap("Prescriptions")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the multi select on screen") { sdk.isShowing(Self.multi) }
    }

    // Fails if: canvas_survey_answer_inputs.swift `maxSelectionsMessage` stops using the singular
    // ("Select at most 1 options"), or the cap check lets the second choice through.
    @Test("a multi select capped at one refuses a second choice and says so in the singular")
    func capOfOne() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.input("scene_multi")["maximumSelections"] = 1
        let sdk = try await open(campaign)
        defer { sdk.tearDown() }
        try await reachMulti(sdk)

        try await sdk.surveyCanvasTap("Search")
        try await sdk.surveyCanvasTap("Checkout")
        try await sdk.waitUntil("the cap is explained") { sdk.isShowing("Select at most 1 option") }
        #expect(!sdk.isShowing("Select at most 1 options"))

        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }
        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_multi")
        #expect(answers == [["m_search"]])
    }

    // Fails if: canvas_survey_input_parser.swift stops reading "upvote" (the input becomes a plain
    // single select without its arrow), or canvas_survey_answer_inputs.swift
    // `if inputType == .upvote` stops drawing it; or an upvote starts collecting several choices.
    @Test("an upvote list shows an arrow per option and keeps one choice")
    func upvote() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.input("scene_single")["type"] = "upvote"
        let sdk = try await open(campaign)
        defer { sdk.tearDown() }

        #expect(sdk.surveyCanvasFrames("\u{2191}").count == 3)

        try await sdk.surveyCanvasTap("Prescriptions")
        try await sdk.surveyCanvasTap("Devices")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the multi select on screen") { sdk.isShowing(Self.multi) }
        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_single")
        #expect(answers == [["o_devices"]])
    }
}
}
