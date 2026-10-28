import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `survey_validation_rules`: a respondent works through six questions, each with one rule at its
/// limit. Every case types or taps on the real survey and reads what the respondent is told, so a
/// limit that moves by one, or a rule applied to the wrong kind of question, changes what is on
/// screen.
///
/// The scenes are, in order: nickname (text, 3..10 characters, plus numeric limits 100..200 a text
/// field must ignore), age (number, 18..65), email, topics (multi select, at most 2), rating
/// (1..5), and an optional note (5..8 characters, which must not be checked).
///
/// Port of `flutter/core/test/fixture_behaviour/survey_validation_rules_test.dart`.
@Suite("Survey: validation rules", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyValidationRulesTests {

    private static let key = "test_survey_validation_rules"
    private static let nickname = "Pick a nickname (3 to 10 characters)"
    private static let age = "Enter your age (18 to 65)"
    private static let email = "Where can we reach you?"
    private static let topics = "Pick up to 2 topics"
    private static let rating = "Rate your last order"
    private static let note = "Anything else? (optional, 5+ characters if you write one)"

    private func open() async throws -> SdkHarness {
        let sdk = try await SdkHarness.surveyGuideStart(["campaigns/survey/survey_validation_rules.json"])
        try await sdk.openSurvey(Self.key, firstText: Self.nickname)
        return sdk
    }

    /// Types [text], taps Next.
    private func answer(_ sdk: SdkHarness, _ text: String) async throws {
        try await sdk.type(text)
        try await sdk.surveyNext()
    }

    /// Answers [text] and waits for [next] to be on screen.
    private func answer(_ sdk: SdkHarness, _ text: String, reaching next: String) async throws {
        try await answer(sdk, text)
        try await sdk.waitUntil("\"\(next)\" on screen") { sdk.isShowing(next) }
    }

    /// Answers the first three questions validly, landing on the topics.
    private func reachTopics(_ sdk: SdkHarness) async throws {
        try await answer(sdk, "abc", reaching: Self.age)
        try await answer(sdk, "30", reaching: Self.email)
        try await answer(sdk, "asha@example.com", reaching: Self.topics)
    }

    /// Answers through the rating (4 stars), landing on the optional note.
    private func reachNote(_ sdk: SdkHarness) async throws {
        try await reachTopics(sdk)
        try await sdk.tapExact("Search")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }
        try await sdk.tapExact("4")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the note on screen") { sdk.isShowing(Self.note) }
    }

    // Fails if: canvas_survey_answer_validator.swift `value.count > maxLength` becomes
    // `value.count >= maxLength` (the 10-character answer is refused), or `value.count < minLength`
    // stops refusing "ab".
    @Test("a text answer is held to its length, inclusively")
    func textLengthIsInclusive() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }

        try await answer(sdk, "ab")
        try await sdk.waitUntil("the minimum is enforced") { sdk.isShowing("Enter at least 3 characters") }
        #expect(sdk.isShowing(Self.nickname))

        try await answer(sdk, "abcdefghijk")
        try await sdk.waitUntil("the maximum is enforced") { sdk.isShowing("Enter at most 10 characters") }
        #expect(sdk.isShowing(Self.nickname))

        try await answer(sdk, "abcdefghij", reaching: Self.age)
    }

    // Fails if: canvas_survey_answer_validator.swift `if type == .number` is dropped (the text
    // answer "abc" is then checked against 100..200), or `value.count < minLength` becomes `<=`.
    @Test("a text question accepts exactly its minimum length and ignores the numeric limits the payload also carries")
    func textIgnoresNumericLimits() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }

        try await answer(sdk, "abc", reaching: Self.age)

        #expect(!sdk.isShowing("Must be at"))
        #expect(!sdk.isShowing("Enter a valid number"))
    }

    // Fails if: canvas_survey_answer_validator.swift `parsed > maximum` becomes `parsed >= maximum`
    // (65 refused) or `parsed < minimum` becomes `parsed <= minimum` (18 refused).
    @Test("a number is held to its bounds, inclusively")
    func numberBoundsAreInclusive() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await answer(sdk, "abc", reaching: Self.age)

        try await answer(sdk, "17")
        try await sdk.waitUntil("the minimum is enforced") { sdk.isShowing("Must be at least 18") }

        try await answer(sdk, "66")
        try await sdk.waitUntil("the maximum is enforced") { sdk.isShowing("Must be at most 65") }

        // Not a number at all: `Double(trimmed)` is nil.
        try await answer(sdk, "abc")
        try await sdk.waitUntil("a non-number is refused") { sdk.isShowing("Enter a valid number") }

        try await answer(sdk, "65", reaching: Self.email)
        try await sdk.surveyBack()
        try await sdk.waitUntil("back on the age") { sdk.isShowing(Self.age) }
        try await answer(sdk, "18", reaching: Self.email)
    }

    // Fails if: canvas_survey_answer_validator.swift `emailIsValid(trimmed)` checks the untrimmed
    // value, or the email check is dropped.
    @Test("an email must look like an address, spaces trimmed")
    func emailIsTrimmedAndChecked() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await answer(sdk, "abc", reaching: Self.age)
        try await answer(sdk, "30", reaching: Self.email)

        try await answer(sdk, "not-an-email")
        try await sdk.waitUntil("a bad address is refused") { sdk.isShowing("Enter a valid email address") }
        #expect(sdk.isShowing(Self.email))

        try await answer(sdk, "  asha@example.com ", reaching: Self.topics)
    }

    // Fails if: canvas_survey_answer_inputs.swift `values.count > maximum` in the choice tile's tap
    // becomes `values.count > maximum + 1`, or its early `return` is dropped (the third choice is
    // then recorded).
    @Test("a multi select refuses a selection past its cap")
    func multiSelectRefusesPastCap() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await reachTopics(sdk)

        // A required question with nothing chosen is refused.
        try await sdk.surveyNext()
        try await sdk.waitUntil("an empty choice is refused") { sdk.isShowing("Select at least one option") }
        #expect(sdk.isShowing(Self.topics))

        try await sdk.tapExact("Search")
        try await sdk.tapExact("Checkout")
        try await sdk.tapExact("Delivery")
        try await sdk.waitUntil("the cap is enforced") { sdk.isShowing("Select at most 2 options") }

        // The refused third choice was not recorded: the two before it go through.
        try await sdk.surveyNext()
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }
        let answered = try await sdk.tracked("Digia Question Answered", of: Self.key)
        let answer = try #require(answered.last.map(SdkHarness.props)?["answer"] as? [String: Any])
        #expect(Set(answer["values"] as? [String] ?? []) == ["t_search", "t_checkout"])
    }

    // Fails if: canvas_survey_answer_validator.swift `missingAnswerMessage` stops answering a scale
    // input with "Choose a rating", or a scale with no value passes validation.
    @Test("a required rating must be chosen")
    func ratingIsRequired() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await reachTopics(sdk)
        try await sdk.tapExact("Search")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the rating on screen") { sdk.isShowing(Self.rating) }

        try await sdk.surveyNext()
        try await sdk.waitUntil("an empty rating is refused") { sdk.isShowing("Choose a rating") }
        #expect(sdk.isShowing(Self.rating))

        try await sdk.tapExact("4")
        try await sdk.surveyNext()
        try await sdk.waitUntil("the note on screen") { sdk.isShowing(Self.note) }
    }

    // Fails if: canvas_survey_answer_validator.swift `guard let input, input.required` stops
    // letting an optional question through (the 2-character note is then refused).
    @Test("an optional question is not checked against its limits, and what was written is still kept")
    func optionalIsNotChecked() async throws {
        let sdk = try await open()
        defer { sdk.tearDown() }
        try await reachNote(sdk)

        try await answer(sdk, "ab", reaching: "Thanks for the details")

        #expect(!sdk.isShowing("Enter at least"))
        let completed = try await sdk.only("Digia Experience Completed", of: Self.key)
        let response = completed["response"] as? [String: Any]
        let note = try #require(surveyAnswer(response, "node_scene_note"))
        #expect(note.values == ["ab"])
        #expect(note.noComment)
        let nickname = try #require(surveyAnswer(response, "node_scene_nickname"))
        #expect(nickname.values == ["abc"])
        #expect(nickname.noComment)

        // The completed answers also reach the backend as one submission.
        let submissions = try await sdk.submissions()
        #expect(submissions.count == 1)
        let completion = (submissions.first?["payload"] as? [String: Any])?["completion"] as? [String: Any]
        #expect(completion?["answeredCount"] as? Int == 6)
    }
}
}
