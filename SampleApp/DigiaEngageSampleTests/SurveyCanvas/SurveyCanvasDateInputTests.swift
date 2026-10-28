import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// `survey_canvas_inputs/survey_canvas_dates_and_cap`: two date questions answered in the
/// platform date picker (a required one bounded to 2024-01-10..2024-12-31, shown month first, with
/// a default before that range; an optional one, shown year first, whose authored range is
/// inverted), then a multi select capped at two. The field opens a wheel picker in an alert; the
/// test reads how the SDK set the picker up and answers through it, Done or Cancel, by real touches.
///
/// Port of `android/core/digia-engage/src/test/java/com/digia/engage/fixture_behaviour/SurveyCanvasDatesAndCapTest.kt`
/// (Flutter has no date-input test). Its cap case is already covered by
/// `FixtureBehaviour/SurveyGuide/SurveyValidationRulesTests` ("a multi select refuses a selection
/// past its cap") and is not repeated; Cancel, Back, and the day-first format are added here.
@Suite("Canvas survey: date input", .serialized, .tags(.integration, .behaviour, .survey))
@MainActor
struct SurveyCanvasDateInputTests {

    private static let fixturePath = "survey_canvas_inputs/survey_canvas_dates_and_cap"
    private static let first = "When did you start?"
    private static let second = "Any date you like?"

    private func open(_ campaign: SurveyCanvasCampaign? = nil) async throws -> (SdkHarness, String) {
        let campaign = try campaign ?? SurveyCanvasCampaign(Self.fixturePath)
        let sdk = try await SdkHarness.surveyCanvasStart(campaign)
        try await sdk.surveyCanvasOpen(campaign.key, firstText: Self.first)
        return (sdk, campaign.key)
    }

    /// Taps the date field showing [field] and returns the picker it opens.
    private func openPicker(_ sdk: SdkHarness, _ field: String) async throws -> UIDatePicker {
        try await sdk.surveyCanvasTap(field)
        try await sdk.waitUntil("the date picker is up") { sdk.surveyCanvasView(UIDatePicker.self) != nil }
        let picker = try #require(sdk.surveyCanvasView(UIDatePicker.self))
        #expect(picker.datePickerMode == .date)
        return picker
    }

    /// Picks [iso] (yyyy-MM-dd) in [picker] and taps Done, as the respondent's choice would.
    private func choose(_ sdk: SdkHarness, _ picker: UIDatePicker, _ iso: String) async throws {
        picker.date = try Self.date(iso)
        try await sdk.surveyCanvasTap("Done")
        try await sdk.waitUntil("the picker is gone") { sdk.surveyCanvasView(UIDatePicker.self) == nil }
    }

    /// Noon on [iso] in the gregorian calendar, as the SDK reads authored dates.
    private static func date(_ iso: String) throws -> Date {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        try #require(parts.count == 3)
        return try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian), year: parts[0], month: parts[1], day: parts[2], hour: 12
        ).date)
    }

    private static func day(_ date: Date?) -> String? {
        guard let date else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Answers the first date with 2024-03-05 and lands on the second.
    private func answerFirst(_ sdk: SdkHarness) async throws {
        try await choose(sdk, try await openPicker(sdk, "Pick a date"), "2024-03-05")
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the second date question") { sdk.isShowing(Self.second) }
    }

    // Fails if: canvas_survey_answer_inputs.swift stops holding the picker to the authored range
    // (`datePicker.minimumDate` / `maximumDate` in `present(from:)`), or `boundedDate` stops
    // moving a default before the range up to its start.
    @Test("a bounded date opens at the range start when the default falls before it")
    func boundedOpensAtRangeStart() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }

        let picker = try await openPicker(sdk, "Pick a date")

        #expect(Self.day(picker.date) == "2024-01-10")
        #expect(Self.day(picker.minimumDate) == "2024-01-10")
        #expect(Self.day(picker.maximumDate) == "2024-12-31")
    }

    // Fails if: canvas_survey_answer_inputs.swift's Done stops calling `self.select(date)`,
    // `formatIsoDate` changes the shape sent, or `formatDisplayDate`'s `.mmDdYyyy` case stops
    // putting the month first.
    @Test("a chosen date is shown in the authored format and sent as an ISO date")
    func chosenDateShownAndSent() async throws {
        let (sdk, key) = try await open()
        defer { sdk.tearDown() }

        try await choose(sdk, try await openPicker(sdk, "Pick a date"), "2024-03-05")

        try await sdk.waitUntil("shown month first, as authored") { sdk.isShowing("03 / 05 / 2024") }
        #expect(!sdk.isShowing("Pick a date"))
        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the second date question") { sdk.isShowing(Self.second) }
        let answered = try await sdk.surveyCanvasTracked("Digia Question Answered", of: key, atLeast: 1)
        #expect(answered.count == 1)
        #expect((answered.first?["properties"] as? [String: Any])?["answer_value"] as? String == "2024-03-05")
    }

    // Fails if: canvas_survey_answer_inputs.swift `validDateRange` stops rejecting a minimum after
    // the maximum (the picker would get a range holding no date), or the field stops opening at
    // the authored default.
    @Test("an inverted range is ignored and the picker opens at the authored default")
    func invertedRangeIgnored() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await answerFirst(sdk)

        let picker = try await openPicker(sdk, "Any date")

        #expect(Self.day(picker.date) == "2020-05-05")
        #expect(picker.minimumDate == nil)
        #expect(picker.maximumDate == nil)
        try await choose(sdk, picker, "2019-12-31")
        try await sdk.waitUntil("shown year first, as authored") { sdk.isShowing("2019-12-31") }
    }

    // Fails if: canvas_survey_answer_inputs.swift's Cancel starts selecting the picker's date
    // (its action calling `select` like Done's), so a cancelled required date would pass.
    @Test("Cancel leaves a required date unanswered, and Next says so")
    func cancelLeavesUnanswered() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }

        let picker = try await openPicker(sdk, "Pick a date")
        picker.date = try Self.date("2024-03-05")
        try await sdk.surveyCanvasTap("Cancel")
        try await sdk.waitUntil("the picker is gone") { sdk.surveyCanvasView(UIDatePicker.self) == nil }
        #expect(sdk.isShowing("Pick a date"))

        try await sdk.surveyCanvasTap("Next")
        try await sdk.waitUntil("the empty date is refused") { sdk.isShowing("This field is required") }
        #expect(!sdk.isShowing(Self.second))
    }

    // Fails if: canvas_survey_answer_inputs.swift's date field stops restoring the answer when it
    // appears again (`value = answer?.values.first ?? ""` / `selectedDate = parseIsoDate(value)`).
    @Test("going Back to an answered date shows it again, and the picker reopens on it")
    func backRestoresDate() async throws {
        let (sdk, _) = try await open()
        defer { sdk.tearDown() }
        try await answerFirst(sdk)

        try await sdk.surveyCanvasTap("Back")
        try await sdk.waitUntil("the first date is shown again") { sdk.isShowing("03 / 05 / 2024") }
        let reopened = try await openPicker(sdk, "03 / 05 / 2024")
        #expect(Self.day(reopened.date) == "2024-03-05")
    }

    // Fails if: canvas_survey_input_parser.swift `dateFormat` stops defaulting to day first, or
    // canvas_survey_answer_inputs.swift `formatDisplayDate`'s `.ddMmYyyy` case swaps day and month.
    @Test("a date with no authored format is shown day first")
    func defaultFormatIsDayFirst() async throws {
        let campaign = try SurveyCanvasCampaign(Self.fixturePath)
        try campaign.input("scene_date").removeObject(forKey: "dateFormat")
        let (sdk, _) = try await open(campaign)
        defer { sdk.tearDown() }

        try await choose(sdk, try await openPicker(sdk, "Pick a date"), "2024-03-05")
        try await sdk.waitUntil("shown day first") { sdk.isShowing("05 / 03 / 2024") }
    }
}
}
