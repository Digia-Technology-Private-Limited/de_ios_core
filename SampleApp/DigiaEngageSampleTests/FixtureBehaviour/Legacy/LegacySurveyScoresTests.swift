import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Legacy block-based survey in a bottom sheet that advances itself: `legacy_survey/
/// legacy_survey_scores_sheet`. A text/media intro (the timer is paused on it), star rating, NPS
/// (a detractor score branches to an open question that ends the survey), a five-face scale and a
/// three-face scale shown only when the faces answer is above 2, and a result page. Auto-advance is
/// on and the Next button is off for the single-pick blocks; a five-minute timer runs.
///
/// iOS only: Flutter no longer reads this shape. The cases follow
/// `flutter/core/test/fixture_behaviour/survey_branching_rules_test.dart` (branch, complete) and
/// `survey_welcome_backdrop_test.dart` (a locked backdrop).
@Suite("Legacy survey: score blocks in a sheet", .serialized,
       .tags(.integration, .behaviour, .survey))
@MainActor
struct LegacySurveyScoresTests {

    private static let key = "test_legacy_survey_scores"
    private static let intro = "Rate your last order"
    private static let stars = "How was the delivery?"
    private static let nps = "How likely are you to recommend us?"
    private static let why = "What went wrong?"
    private static let mood = "How do you feel about the food?"
    private static let pack = "And the packaging?"
    private static let thanks = "Thanks, see you soon!"

    private func open(_ campaign: [String: Any]? = nil) async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([campaign ?? fixture("legacy_survey/legacy_survey_scores_sheet")])
        let presentation = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the intro", timeout: 4) { sdk.isShowing(Self.intro) }
        return (sdk, presentation)
    }

    /// Past the intro, a star and onto the NPS question.
    private func openOnNps() async throws -> (SdkHarness, CampaignPresentation) {
        let (sdk, presentation) = try await open()
        try await sdk.legacyTapExact("Next")
        try await sdk.waitUntil("the stars") { sdk.isShowing(Self.stars) }
        try await sdk.legacyTapExact("4")
        try await sdk.waitUntil("the NPS question") { sdk.isShowing(Self.nps) }
        return (sdk, presentation)
    }

    // Fails if `SurveyBody.startTimer` stops honouring `paused` (the chip would count down on the
    // intro), or `scheduleAutoAdvanceIfNeeded` stops advancing an answered single-pick block.
    @Test("the timer waits on the intro; a star answer advances by itself and the timer runs")
    func timerPausesThenAutoAdvance() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        #expect(sdk.legacyIsShowingExact("5:00"))
        try await sdk.settle(1.3)
        #expect(sdk.legacyIsShowingExact("5:00"), "paused on a content block")

        try await sdk.legacyTapExact("Next")
        try await sdk.waitUntil("the stars") { sdk.isShowing(Self.stars) }
        // Auto-advance with chooseButton off: there is no Next on a single-pick block.
        #expect(!sdk.legacyIsShowingExact("Next"))
        try await sdk.legacyTapExact("4")
        try await sdk.waitUntil("the NPS question") { sdk.isShowing(Self.nps) }

        let answered = try await sdk.legacyOnly("Digia Question Answered", of: Self.key)
        #expect(answered["question_id"] as? String == "n_stars")
        #expect(answered["answer_value"] as? String == "4")
        try await sdk.waitUntil("the timer counts down", timeout: 3) { !sdk.legacyIsShowingExact("5:00") }
    }

    // Fails if a `less_than` rule stops matching below its value (`n < t` in
    // `SurveyLogicHandler.evaluate`), an `end` target stops finishing the survey, or
    // `SubmissionReporter.npsBucket` misplaces 3.
    @Test("a detractor score branches to the open question, whose Done completes and submits")
    func detractorBranchCompletes() async throws {
        let (sdk, presentation) = try await openOnNps()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("3")
        try await sdk.waitUntil("the open question") { sdk.isShowing(Self.why) }
        try await sdk.legacyType("Cold fries")
        try await sdk.legacyTapExact("Done")

        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .completed)
        #expect(!sdk.isShowing(Self.mood))
        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        #expect((body["computed"] as? [String: Any])?["npsBucket"] as? String == "detractor")
        #expect(legacyResponse(body, "b_nps")?["value"] as? Int == 3)
        #expect(legacyResponse(body, "b_stars")?["value"] as? Int == 4)
        #expect(legacyResponse(body, "b_why")?["blockType"] as? String == "long_text")
        #expect(legacyResponse(body, "b_why")?["value"] as? String == "Cold fries")
        _ = try await sdk.legacyOnly("Digia Experience Completed", of: Self.key)
    }

    // Fails if `showWhen` stops being read for a node (`isVisible` in `scanForwardFrom`), or the
    // face scale's answer stops being its 1-based index (`values: ["\(value)"]` in NpsFaceQuestion).
    @Test("a promoter goes to the faces; a happy face shows the packaging scale before the result")
    func promoterHappyPath() async throws {
        let (sdk, presentation) = try await openOnNps()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("9")
        try await sdk.waitUntil("the faces question") { sdk.isShowing(Self.mood) }
        #expect(!sdk.isShowing("A face without an emoji is dropped"))
        try await sdk.legacyTapPrefix("😐")
        try await sdk.waitUntil("the packaging question") { sdk.isShowing(Self.pack) }
        // `showFaceLabels: false`: the faces show no caption.
        #expect(!sdk.isShowing("Nice"))
        try await sdk.legacyTapPrefix("😊")
        try await sdk.waitUntil("the result page") { sdk.isShowing(Self.thanks) }

        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        #expect((body["computed"] as? [String: Any])?["npsBucket"] as? String == "promoter")
        #expect(legacyResponse(body, "b_mood")?["value"] as? String == "3")
        #expect(legacyResponse(body, "b_pack")?["value"] as? String == "3")

        try await sdk.legacyTapExact("Done")
        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .completed)
    }

    // Same `showWhen` line, the other way: 1 is not above 2, so the packaging node is skipped.
    @Test("an unhappy face skips the packaging scale straight to the result")
    func unhappyFaceSkipsPackaging() async throws {
        let (sdk, _) = try await openOnNps()
        defer { sdk.tearDown() }

        try await sdk.legacyTapExact("10")
        try await sdk.waitUntil("the faces question") { sdk.isShowing(Self.mood) }
        try await sdk.legacyTapPrefix("😡")
        try await sdk.waitUntil("the result page") { sdk.isShowing(Self.thanks) }

        #expect(!sdk.isShowing(Self.pack))
        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        #expect(legacyResponse(body, "b_pack") == nil)
    }

    // Fails if `SurveySheet` stops honouring `backdropDismissible: false`, or the sheet's close
    // button stops ending the survey as a user close.
    @Test("a locked backdrop keeps the sheet; its close button ends it")
    func lockedBackdropThenClose() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }
        try await sdk.settle(0.5)

        try sdk.legacyTapBackdrop()
        try await sdk.settle(0.4)
        #expect(sdk.isShowing(Self.intro))
        #expect(presentation.outcome.settledValue == nil)

        try await sdk.legacyTapExact("Close survey")
        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .userClose)
    }

}
}
