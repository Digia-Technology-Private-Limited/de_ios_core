import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// Legacy block-based survey of text inputs in a dialog, delivered under `surveyConfig` (the older
/// envelope): `legacy_survey/legacy_survey_text_inputs`. Short text (required), long text
/// (optional), number (13–120), email (optional) and a date shown only when the email was given;
/// no welcome and no result page, so the last answer's Submit completes the survey. The backdrop is
/// locked.
///
/// iOS only: Flutter no longer reads this shape. The cases follow
/// `flutter/core/test/fixture_behaviour/survey_validation_rules_test.dart`.
@Suite("Legacy survey: text inputs in a dialog", .serialized,
       .tags(.integration, .behaviour, .survey))
@MainActor
struct LegacySurveyInputsTests {

    private static let key = "test_legacy_survey_inputs"
    private static let name = "What should we call you?"
    private static let story = "Tell us about your week (optional)"
    private static let age = "How old are you?"
    private static let email = "Email for a summary (optional)"
    private static let date = "When did you join? (optional)"

    private func open() async throws -> (SdkHarness, CampaignPresentation) {
        let sdk = try await SdkHarness.legacyStart([fixture("legacy_survey/legacy_survey_text_inputs")])
        let presentation = try sdk.deliver(Self.key)
        try await sdk.waitUntil("the first question", timeout: 4) { sdk.isShowing(Self.name) }
        return (sdk, presentation)
    }

    private func next(_ sdk: SdkHarness, to text: String) async throws {
        try await sdk.legacyTapExact("Next")
        try await sdk.waitUntil("\"\(text)\" on screen") { sdk.isShowing(text) }
    }

    /// Answers the name, skips the story, and lands on the age question.
    private func openOnAge() async throws -> (SdkHarness, CampaignPresentation) {
        let (sdk, presentation) = try await open()
        try await sdk.legacyType("Asha")
        try await next(sdk, to: Self.story)
        try await next(sdk, to: Self.age)
        return (sdk, presentation)
    }

    // Fails if `validateNumber` stops checking a bound (`if let min, n < min` /
    // `if let max, n > max`), or `SurveyTextQuestion.handle` stops clearing the answer on an error
    // (Next would stay enabled and accept 9).
    @Test("a number outside its range shows why and cannot be sent; one inside can")
    func numberRange() async throws {
        let (sdk, _) = try await openOnAge()
        defer { sdk.tearDown() }

        try await sdk.legacyType("9", keepFocus: true)
        #expect(sdk.isShowing("Must be at least 13"), "\(sdk.legacyShownTexts())")
        sdk.legacyDismissKeyboard()
        withKnownIssue("The legacy dialog forgets the entry and its error when the keyboard goes") {
            #expect(sdk.isShowing("Must be at least 13"), "\(sdk.legacyShownTexts())")
            #expect(sdk.legacyFieldText() == "9")
        }
        try await sdk.legacyTapExact("Next")
        try await sdk.settle(0.3)
        #expect(sdk.isShowing(Self.age))

        try await sdk.legacyType("130", keepFocus: true)
        #expect(sdk.isShowing("Must be at most 120"), "\(sdk.legacyShownTexts())")
        sdk.legacyDismissKeyboard()

        try await sdk.legacyType("34")
        #expect(!sdk.isShowing("Must be at"))
        try await next(sdk, to: Self.email)
    }

    // Fails if `validateEmail` / `validateDate` accept what they should not (the date regex, or the
    // leap-year day count `case 2: maxDay = ... ? 29 : 28`), or `showWhen` `is_answered` stops
    // reading the earlier node; and if `SubmissionReporter` stops submitting a survey that ends on
    // its last node without a result page.
    @Test("the whole survey with every input checked, ended by Submit, then submitted")
    func wholeSurvey() async throws {
        let (sdk, presentation) = try await openOnAge()
        defer { sdk.tearDown() }
        try await sdk.legacyType("34")
        try await next(sdk, to: Self.email)

        try await sdk.legacyType("asha@", keepFocus: true)
        #expect(sdk.isShowing("Enter a valid email address"), "\(sdk.legacyShownTexts())")
        try await sdk.legacyType("asha@example.com")
        try await next(sdk, to: Self.date)

        try await sdk.legacyType("2023-02-29", keepFocus: true)
        #expect(sdk.isShowing("Day must be 01–28"), "\(sdk.legacyShownTexts())")
        try await sdk.legacyType("2024/02/29", keepFocus: true)
        #expect(sdk.isShowing("Use format YYYY-MM-DD"), "\(sdk.legacyShownTexts())")
        try await sdk.legacyType("2024-02-29")
        #expect(!sdk.isShowing("Day must be"))
        // The last node: the footer reads the authored done label.
        try await sdk.legacyTapExact("Submit")

        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .completed)
        let skipped = try await sdk.legacyTracked("Digia Question Skipped", of: Self.key)
        #expect(skipped.compactMap { ($0["properties"] as? [String: Any])?["question_id"] as? String } == ["n_story"])
        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        #expect(body["campaignId"] as? String == "mock-legacy-survey-inputs-001")
        let completion = (body["payload"] as? [String: Any])?["completion"] as? [String: Any]
        #expect(completion?["answeredCount"] as? Int == 4)
        #expect(completion?["totalCount"] as? Int == 5)
        #expect(legacyResponse(body, "b_name")?["value"] as? String == "Asha")
        #expect(legacyResponse(body, "b_age")?["value"] as? Int == 34)
        #expect(legacyResponse(body, "b_email")?["value"] as? String == "asha@example.com")
        #expect(legacyResponse(body, "b_date")?["value"] as? String == "2024-02-29")
    }

    // Same `showWhen` line, the other way: no email, so the date node is skipped and the survey
    // ends after the email question.
    @Test("leaving the optional email empty skips the date and ends the survey")
    func noEmailSkipsDate() async throws {
        let (sdk, presentation) = try await openOnAge()
        defer { sdk.tearDown() }
        try await sdk.legacyType("34")
        try await next(sdk, to: Self.email)

        try await sdk.legacyTapExact("Next")

        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .completed)
        #expect(!sdk.isShowing(Self.date))
        let body = try #require(try await sdk.legacySubmissions().first, "a /recordSubmission body")
        #expect(legacyResponse(body, "b_date") == nil)
    }

    // Fails if a required short text stops blocking Next while empty (`canAdvance`), or
    // `DialogContainer` stops honouring `backdropDismissible: false`.
    @Test("an empty required answer blocks Next; the locked backdrop does nothing; Close ends it")
    func requiredLockedBackdropAndClose() async throws {
        let (sdk, presentation) = try await open()
        defer { sdk.tearDown() }
        #expect(sdk.legacyIsShowingExact("1/5"))
        // `showTag: false`: no category pill above the title.
        #expect(!sdk.legacyIsShowingExact("SHORT TEXT"))

        try await sdk.legacyTapExact("Next")
        try await sdk.settle(0.3)
        #expect(sdk.isShowing(Self.name))

        try sdk.legacyTapBackdrop()
        try await sdk.settle(0.3)
        #expect(sdk.isShowing(Self.name))
        #expect(presentation.outcome.settledValue == nil)

        try await sdk.legacyTapExact("Close survey")
        try await sdk.waitUntil("the survey closed") { presentation.outcome.settledValue != nil }
        #expect(presentation.dismissReason == .userClose)
    }
}
}
