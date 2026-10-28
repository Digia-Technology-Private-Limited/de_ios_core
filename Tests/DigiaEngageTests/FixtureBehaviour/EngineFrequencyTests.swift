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

    private static let day: TimeInterval = 86_400
    private static let title = "Once A Week, Twice Ever"

    private func boot(stored: (String) -> [String: Any] = { _ in [:] }) async throws -> (SdkHarness, key: String) {
        let campaign = try fixture("engine/engine_frequency_week_window_total_cap")
        let key = keyOf(campaign)
        let sdk = try await SdkHarness.start(campaign, stored: stored(key))
        try sdk.mount { Text("host app") }
        return (sdk, key)
    }

    // Fails if a recorded show stops being counted, or the window stops blocking: the window
    // test `effective >= count` becomes `effective > count` in `frequency_manager.swift`.
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

    // Fails if the week stops being 7 days long.
    @Test("a show six days ago still blocks")
    func sixDaysAgoStillBlocks() async throws {
        let (sdk, key) = try await boot { key in
            SdkHarness.frequencyState(
                key, total: 1, windowCount: 1, windowAnchorAt: SdkHarness.msAgo(seconds: 6 * Self.day))
        }
        defer { sdk.tearDown() }

        let delivery = try sdk.deliver(key)
        try await sdk.settle()

        #expect(delivery.dropReason == .frequencyCapped)
        #expect(!sdk.isShowing(Self.title))
    }

    // Same line, other direction: an 8-day-old show must have rolled out of the week.
    @Test("a show eight days ago has rolled out of the week")
    func eightDaysAgoHasRolledOut() async throws {
        let (sdk, key) = try await boot { key in
            SdkHarness.frequencyState(
                key, total: 1, windowCount: 1, windowAnchorAt: SdkHarness.msAgo(seconds: 8 * Self.day))
        }
        defer { sdk.tearDown() }

        let delivery = try sdk.deliver(key)
        try await sdk.waitUntil("the nudge is up") { sdk.isShowing(Self.title) }

        #expect(delivery.dropReason == nil)
    }

    // Fails if the lifetime cap is dropped from the gate (`total >= maxTotal` becomes `>`).
    @Test("the lifetime cap of two blocks even though the week rolled")
    func lifetimeCapBlocks() async throws {
        let (sdk, key) = try await boot { key in
            SdkHarness.frequencyState(
                key, total: 2, windowCount: 1, windowAnchorAt: SdkHarness.msAgo(seconds: 8 * Self.day))
        }
        defer { sdk.tearDown() }

        let delivery = try sdk.deliver(key)
        try await sdk.settle()

        #expect(delivery.dropReason == .frequencyCapped)
        #expect(!sdk.isShowing(Self.title))
    }
}
}
