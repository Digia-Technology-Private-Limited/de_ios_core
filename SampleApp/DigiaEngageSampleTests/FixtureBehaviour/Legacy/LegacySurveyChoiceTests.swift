import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Legacy block-based survey in a dialog: `legacy_survey/legacy_survey_choice_dialog`, read by
/// `SurveyConfigModel.from` and drawn by `SurveyBody` / `SurveyQuestionContent`. A welcome screen,
/// then single select (descriptions, "Other"), multi select (grid, media), reaction (the fallback
/// emoji set), this-or-that, tier list, upvote, a text/media page and a result page, with an `or`
/// rule on the first question that skips the second.
///
/// iOS only: Flutter no longer reads this shape. The cases follow
/// `flutter/core/test/fixture_behaviour/survey_branching_rules_test.dart` and
/// `survey_welcome_backdrop_test.dart` (open, answer, branch, complete, close).
@Suite("Legacy survey: choice blocks in a dialog", .serialized,
       .tags(.integration, .behaviour, .survey))
@MainActor
struct LegacySurveyChoiceTests {

    private static let key = "test_legacy_survey_choice"
    private static let welcome = "Help us build a better app"
    private static let role = "What best describes your role?"
    private static let tools = "Which tools do you use daily?"
    private static let vibe = "How do you feel about the app today?"
    private static let pick = "Dark mode or light mode?"
    private static let rank = "Rank these features"
    private static let vote = "Which should we build next?"
    private static let note = "Almost there"
    private static let result = "Thanks for the feedback!"

    private func open() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([fixture("legacy_survey/legacy_survey_choice_dialog")])
        let presentation = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the welcome screen", timeout: 4) { sdk.isShowing(Self.welcome) }
        return (sdk, presentation)
    }

    /// Opens past the welcome screen onto the role question.
    private func openOnRole() async throws -> (SdkHarness, CampaignPresentation) {
        let (sdk, presentation) = try await open()
        try await sdk.legacyTapExact("Let's go")
        try await sdk.waitUntil("the role question") { sdk.isShowing(Self.role) }
        return (sdk, presentation)
    }

    private func next(_ sdk: SdkHarness, to text: String) async throws {
        try await sdk.legacyTapExact("Continue")
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
    }

    // Fails if `SurveyBody.welcomeScreen`'s Start stops calling `reportSurveyWelcomeStart()`, or
    // `SurveyConfigModel.from` keeps the legacy welcome node (the flow would start on it again).
    @Test("the welcome screen comes first; its Start reports welcome_start and opens the first question")
    func welcomeThenFirstQuestion() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        #expect(!sdk.isShowing(Self.role))
        let viewed = try await sdk.legacyOnly("Digia Experience Viewed", of: Self.key)
        #expect(viewed["has_welcome"] as? Bool == true)

        try await sdk.legacyTapExact("Let's go")
        try await sdk.waitUntil("the role question") { sdk.isShowing(Self.role) }

        let clicked = try await sdk.legacyOnly("Digia Experience Clicked", of: Self.key)
        #expect(clicked["element_id"] as? String == "welcome_start")
        // The orphan node (blank blockId) and the welcome node are not in the flow: 8 pages.
        #expect(sdk.legacyIsShowingExact("1/8"))
        #expect(sdk.isShowing("I write the code"), "option descriptions are shown")
        #expect(sdk.legacyIsShowingExact("SELECT ONE ANSWER"))
    }

    // Fails if `SurveyViewModel.canAdvance` stops returning false for an unanswered required block,
    // or `FooterRow.nextButton` loses `.disabled(!nextEnabled)`.
    @Test("a required question cannot be left until it is answered")
    func requiredBlocksContinue() async throws {
        let (sdk, _) = try await openOnRole()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("Continue")
        try await sdk.settle(0.3)
        #expect(sdk.isShowing(Self.role))

        try await sdk.legacyTapPrefix("Developer")
        try await next(sdk, to: Self.tools)
        #expect(!sdk.isShowing(Self.role))
    }

    // Fails if a by_condition `or` group stops passing on any one condition
    // (`case .or: return conditionResults.contains { $0 }` in `SurveyLogicHandler`), or a rule's
    // `node` target stops being followed.
    @Test("either answer of the or-rule skips the tools question", arguments: ["Designer", "Product manager"])
    func orRuleSkipsAhead(answer: String) async throws {
        let (sdk, _) = try await openOnRole()
        defer { sdk.tearDown() }

        try await sdk.legacyTapPrefix(answer)
        try await next(sdk, to: Self.vibe)

        #expect(!sdk.isShowing(Self.tools))
        // The reaction block authored no options, so it shows the fallback emoji set.
        #expect(sdk.legacyIsShowingExact("🔥"))
    }

    // Fails if `SurveyViewModel.back()` stops popping the back stack, or the choice card stops
    // hydrating from the kept answer (`answer?.values.forEach { selected[$0] = true }`).
    @Test("Back returns to the previous question with its answer kept")
    func backKeepsTheAnswer() async throws {
        let (sdk, _) = try await openOnRole()
        defer { sdk.tearDown() }
        try await sdk.legacyTapPrefix("Developer")
        try await next(sdk, to: Self.tools)

        try await sdk.legacyTapExact("Back")
        try await sdk.waitUntil("the role question again") { sdk.isShowing(Self.role) }

        // Developer is still chosen, so Continue goes straight on.
        try await next(sdk, to: Self.tools)
    }

    // Fails if `ChoiceCardQuestion.emit` stops carrying the "Other" text as the answer's comment,
    // `SubmissionReporter.buildResponse` drops a block type's value or label, or a skipped optional
    // question stops reporting `Digia Question Skipped`.
    @Test("the whole survey: every block type answered, one skipped, reported and submitted")
    func wholeSurvey() async throws {
        let (sdk, presentation) = try await openOnRole()
        defer { sdk.tearDown() }

        try await sdk.legacyTapPrefix("Other…")
        try await sdk.waitUntil("the other field") { sdk.isShowing("Please specify…") }
        try await sdk.legacyType("Founder")
        // The keyboard resizes `DialogContainer`, whose `dialogSurface` then swaps between its
        // `ContentSizedScrollView` and plain branches: the content is rebuilt and `SurveyBody`
        // loses its `@State welcomeDone`, so the welcome screen comes back mid-survey.
        withKnownIssue("The keyboard sends a legacy dialog survey back to its welcome screen") {
            #expect(!sdk.isShowing(Self.welcome), "\(sdk.legacyShownTexts())")
        }
        if sdk.isShowing(Self.welcome) {
            try await sdk.legacyTapExact("Let's go")
            try await sdk.waitUntil("the role question again") { sdk.isShowing(Self.role) }
        }
        try await next(sdk, to: Self.tools)

        try await sdk.legacyTapPrefix("Xcode")
        try await sdk.legacyTapPrefix("Notion")
        try await next(sdk, to: Self.vibe)

        // The reaction is optional: leave it unanswered.
        try await next(sdk, to: Self.pick)
        #expect(!sdk.legacyIsShowingExact("A third option is never shown"))

        try await sdk.legacyTapExact("Dark")
        try await next(sdk, to: Self.rank)

        // A chip cycles unplaced -> S -> A: two taps put Search in tier A.
        try await sdk.legacyTapExact("Search")
        try await sdk.legacyTapExact("Search")
        try await next(sdk, to: Self.vote)

        try await sdk.legacyTapPrefix("Cloud sync")
        try await next(sdk, to: Self.note)
        #expect(sdk.legacyIsShowingExact("— image / video —"))
        try await next(sdk, to: Self.result)

        let completed = try await sdk.legacyOnly("Digia Experience Completed", of: Self.key)
        #expect(completed["answered_count"] as? Int == 5)
        let skipped = try await sdk.legacyTracked("Digia Question Skipped", of: Self.key)
        #expect(skipped.compactMap { ($0["properties"] as? [String: Any])?["question_id"] as? String } == ["n_vibe"])

        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        let completion = (body["payload"] as? [String: Any])?["completion"] as? [String: Any]
        #expect(completion?["answeredCount"] as? Int == 5)
        #expect(completion?["totalCount"] as? Int == 6)
        let role = legacyResponse(body, "b_role")
        #expect(role?["blockType"] as? String == "single_select")
        #expect(role?["value"] as? String == OTHER_CHOICE_ID)
        #expect(role?["comment"] as? String == "Founder")
        #expect(Set(legacyResponse(body, "b_tools")?["value"] as? [String] ?? []) == ["tool_xcode", "tool_notion"])
        #expect(legacyResponse(body, "b_pick")?["valueLabel"] as? String == "Dark")
        #expect(legacyResponse(body, "b_rank")?["value"] as? [String] == ["A:feat_search"])
        #expect(legacyResponse(body, "b_vote")?["valueLabel"] as? [String] == ["Cloud sync"])
        #expect(legacyResponse(body, "b_vibe") == nil)
        #expect(presentation.outcome.settledValue == nil, "the result page is still up")

        try await sdk.legacyTapExact("Finish")
        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .completed)
        #expect(presentation.legacyCompleted == true)
        #expect(sdk.sdk.surveyOrchestrator.state == nil)
        #expect(try await sdk.legacySubmissions().count == 1, "submitted once")
    }

    // Fails if the top row stops drawing the close button when the dialog authors one
    // (`showCloseButton && survey.settings.display.dismissible` in `SurveyBody.topRow`), or the
    // close stops reporting the item it was abandoned at.
    @Test("the close button ends the survey as a user close, at the item reached")
    func closeButton() async throws {
        let (sdk, presentation) = try await openOnRole()
        defer { sdk.tearDown() }
        try await sdk.legacyTapPrefix("Developer")
        try await next(sdk, to: Self.tools)

        try await sdk.legacyTapExact("Close survey")

        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .userClose)
        #expect(presentation.legacyCompleted == false)
        let dismissed = try await sdk.legacyOnly("Digia Experience Dismissed", of: Self.key)
        #expect(dismissed["abandoned_at_item"] as? Int == 2)
        #expect(try await sdk.legacySubmissions().isEmpty)
    }

    // Fails if `DialogContainer`'s scrim ignores `dialog.backdropDismissible`.
    @Test("a tap on the scrim closes a dialog whose backdrop dismisses")
    func backdropCloses() async throws {
        let (sdk, presentation) = try await openOnRole()
        defer { sdk.tearDown() }

        try sdk.legacyTapBackdrop()

        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .userClose)
    }
}
}
