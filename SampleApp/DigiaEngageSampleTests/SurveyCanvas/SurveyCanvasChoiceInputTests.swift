import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// The choice answer input's branches the fixture suites do not reach: taking back a multi-select
/// choice, a cap of one, the `row` layout, and the `upvote` kind (the uneven `grid` layout is the package's
/// `Tests/DigiaEngageTests/FixtureBehaviour/SurveyCanvasChoiceInputTests.swift`). Each test
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

    // Fails if: canvas_survey_answer_inputs.swift `values.remove(option.id)` in the choice tile's
    // tap stops removing a chosen option (the answer then keeps "m_search").
    @Test("tapping a chosen multi-select option again takes it back")
    func multiSelectToggleOff() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        let sdk = try await open(campaign)
        defer { sdk.tearDown() }
        try await reachMulti(sdk)

        try await sdk.surveyCanvasTap("Search")
        try await sdk.surveyCanvasTap("Checkout")
        try await sdk.surveyCanvasTap("Search")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }

        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_multi")
        #expect(answers == [["m_checkout"]])
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

    /// Flutter lays a `row` out as a `Row` of `Expanded` tiles: every option shares the host's
    /// width and all are on screen (`canvas_survey_choice_input.dart`). iOS puts the tiles in a
    /// horizontal `ScrollView` and gives each `.frame(maxWidth: .infinity)` inside its tile, so
    /// each tile is as wide as the host and only the first option is visible; the respondent
    /// must scroll to find the others (canvas_survey_answer_inputs.swift, `case .row:`).
    ///
    /// Fails if: canvas_survey_answer_inputs.swift's `case .row:` stops laying the options out in
    /// one row (they would stack vertically), or its tiles stop answering. When the row is fixed
    /// to fit the host, the known issue passes and `withKnownIssue` turns this red: drop it then.
    @Test("a row layout puts the options side by side within the host, and they answer")
    func rowLayout() async throws {
        let campaign = try SurveyCanvasCampaign("survey/survey_core_blocks")
        try campaign.answerHostProps("scene_single")["style"] = ["layout": "row"]
        let sdk = try await open(campaign)
        defer { sdk.tearDown() }

        let first = try #require(sdk.surveyCanvasFrames("Prescriptions").first)
        let second = try #require(sdk.surveyCanvasFrames("Wellness").first)
        let third = try #require(sdk.surveyCanvasFrames("Devices").first)
        #expect(abs(first.midY - second.midY) < 2, "\(first) and \(second) are not on one row")
        #expect(second.minX > first.maxX)
        let screen = try #require(sdk.window?.bounds)
        withKnownIssue("iOS row tiles each take the host's full width in a horizontal scroll; Flutter fits all in the host") {
            #expect(third.maxX <= screen.maxX, "the last option is off screen: \(third)")
        }

        try await sdk.surveyCanvasTap("Prescriptions")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the multi select on screen") { sdk.isShowing(Self.multi) }
        let answers = try await sdk.surveyCanvasAnswers(campaign.key, question: "node_scene_single")
        #expect(answers == [["o_rx"]])
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
