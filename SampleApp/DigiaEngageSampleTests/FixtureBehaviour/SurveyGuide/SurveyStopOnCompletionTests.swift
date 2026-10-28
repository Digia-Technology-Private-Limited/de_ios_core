import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// A completed experience can stop a campaign for good. Fixture:
/// `engine_frequency_stop_on_completion` (survey, three ever, stopped by completion).
///
/// Port of the "stop on completion" group of
/// `flutter/core/test/fixture_behaviour/engine_frequency_test.dart`; the nudge caps of that file
/// are in `Tests/DigiaEngageTests/FixtureBehaviour/EngineFrequencyTests.swift`.
@Suite("Engine: stop on completion", .serialized, .tags(.integration, .behaviour, .frequency, .survey))
@MainActor
struct SurveyStopOnCompletionTests {

    private static let question = "Any additional feedback? (Optional)"

    // Fails if: a completion stops being recorded as a permanent stop, or the gate ignores it:
    // SDKInstance.swift `reportSurveyCompleted`'s `frequencyManager.recordCompleted(...)` is
    // dropped, or frequency_manager.swift stops blocking on `stoppedAt`. The lifetime cap is 3 and
    // only 2 showings happened, so only the stop can block the third.
    @Test("a survey completed on its second showing is blocked on the third, though the lifetime cap of three is not reached")
    func completedSurveyIsStopped() async throws {
        let sdk = try await SdkHarness.surveyGuideStart(["campaigns/engine/engine_frequency_stop_on_completion.json"])
        defer { sdk.tearDown() }
        let key = "test_engine_frequency_stop_on_completion"

        // First showing: abandoned from the backdrop. It must not stop anything.
        try await sdk.openSurvey(key, firstText: Self.question)
        try await sdk.settle(0.4) // the dialog ignores its backdrop for its first 350 ms
        try sdk.tapBackdrop()
        try await sdk.waitUntil("the first showing ended") { SDKInstance.shared.surveyOrchestrator.state == nil }

        // Second showing: shown again, and taken to the end.
        let second = try await sdk.openSurvey(key, firstText: Self.question)
        #expect(second.dropReason == nil)
        try await sdk.tapExact("Skip / Next")
        try await sdk.waitUntil("the thank-you page") { sdk.isShowing("Thank you!") }
        try await sdk.tapExact("Done")
        try await sdk.waitUntil("the second showing ended") { SDKInstance.shared.surveyOrchestrator.state == nil }
        #expect(!sdk.isShowing("Thank you!"))

        let third = try sdk.deliver(key)
        try await sdk.settle()

        #expect(third.dropReason == .frequencyCapped)
        #expect(!sdk.isShowing(Self.question))
    }
}
}
