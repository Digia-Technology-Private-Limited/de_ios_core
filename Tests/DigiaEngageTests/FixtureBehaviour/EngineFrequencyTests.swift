import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// Frequency caps persist across showings and across app launches.
///
/// Fixture: `engine_frequency_week_window_total_cap` (nudge, one show a week and two ever). The
/// gate reads the wall clock, so "a show N days ago" is a state an earlier run left in storage,
/// anchored to the real clock.
/// Port of `flutter/core/test/fixture_behaviour/engine_frequency_test.dart`.
@Suite("Engine: frequency caps", .serialized, .tags(.integration, .behaviour, .frequency))
@MainActor
struct EngineFrequencyTests {

    private static let title = "Once A Week, Twice Ever"

    private func boot() async throws -> (SdkHarness, key: String) {
        let campaign = try fixture("engine/engine_frequency_week_window_total_cap")
        let key = keyOf(campaign)
        let sdk = try await SdkHarness.start(campaign)
        try sdk.mount { Text("host app") }
        return (sdk, key)
    }

    // Fails if a recorded show stops being counted, or the window stops blocking: the window
    // test `effective >= count` becomes `effective > count` in `frequency_manager.swift`.
    // dmc-case: dmc.freq.window_caps_day_week_month_rollover
    @Test("a nudge shown this week is capped on the next trigger")
    func shownThisWeekIsCapped() async throws {
        let (sdk, key) = try await boot()
        defer { sdk.tearDown() }
        try sdk.deliver(key)
        try await sdk.waitUntil("the nudge is up") { sdk.isShowing(Self.title) }
        try await sdk.activate(id: "button")
        try await sdk.waitUntil("the nudge is gone") { sdk.sdk.controller.activeNudge == nil }

        let second = try sdk.deliver(key)
        try await sdk.settle()

        #expect(second.dropReason == .frequencyCapped)
        #expect(sdk.sdk.controller.activeNudge == nil)
    }
}
}
