import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// What an inline timer shows as its deadline nears, driven from the shared fixtures
/// `inline_timer/inline_timer_urgent_threshold_boundary`, `inline_timer_teaser_fallback_rules`,
/// `inline_timer_variable_instant_formats` and
/// `inline_timer_variable_deadline_missing_shows_nothing`.
///
/// A countdown reads the server clock the bundle response carries. The boundary tests need that
/// clock to stand at an exact instant, so — as the Flutter tests do — they register the timer slot
/// the way SDK routing stores it, over a clock frozen at the instant each test names
/// (`inlineFrozenClock`). The last two go through the whole SDK: a bundle with a server clock, CEP
/// delivery, routing.
///
/// Port of `flutter/core/test/fixture_behaviour/surface_inline_test.dart` (its `inline timers`
/// group).
@Suite("Inline timers", .serialized, .tags(.integration, .behaviour, .inline))
@MainActor
struct InlineTimerBehaviourTests {

    private static let deadline = inlineUTC("2030-01-01T00:00:00Z")

    /// Boots the SDK, then registers [name] the way routing stores a timer, over a server clock
    /// frozen at [clockAt], and draws its slot. [variables] are the trigger's.
    private func showTimer(
        _ name: String,
        clockAt: Date,
        variables: [String: String]? = nil
    ) async throws -> SdkHarness {
        let json = try fixture("inline_timer/\(name)")
        let sdk = try SdkHarness.create()
        try await sdk.initialize()
        let campaign = try #require(try CampaignModel.fromJson(
            json, designTokens: fixtureTokens(json), timeAnchor: inlineFrozenClock(at: clockAt)))
        guard case .inlineCanvas(let config) = campaign.config else {
            Issue.record("\(name) is not an inline canvas timer")
            throw SdkHarness.TimedOut()
        }
        try #require(config.statefulTimer != nil, "\(name) parsed without its timer")
        let payload = CEPTriggerPayload(
            cepCampaignId: "timer", campaignKey: keyOf(json), cepMetadata: [:], variables: variables)
        sdk.sdk.inlineController.setCanvasConfig(config.slotKey, config: config)
        sdk.sdk.inlineController.setCampaign(config.slotKey, payload: payload)
        _ = try sdk.mountInlineSlot(config.slotKey)
        return sdk
    }

    /// Whether a text view or label shows exactly [text] (a digit box reads "03", which `isShowing`
    /// would also find inside "2030").
    private func showsExactly(_ sdk: SdkHarness, _ text: String) -> Bool {
        guard let window = sdk.window else { return false }
        return SdkHarness.find(in: window) { SdkHarness.shownText(of: $0) == text } != nil
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_canvas_config.swift:85
    // `remainingSeconds <= urgentBelowSeconds` -> `remainingSeconds < urgentBelowSeconds`
    @Test("urgent starts at exactly the threshold and only its first rule shows")
    func urgentStartsAtTheThreshold() async throws {
        // 186313 s is the authored threshold; the countdown rounds up to whole seconds, so
        // 186312.5 s left reads 186313 s: urgent.
        let sdk = try await showTimer(
            "inline_timer_urgent_threshold_boundary",
            clockAt: Self.deadline.addingTimeInterval(-186_312.5))
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the urgent rule is on screen") {
            sdk.isShowing("Hurry: last chance (first urgent rule)")
        }
        #expect(!sdk.isShowing("SECOND URGENT RULE (must never show)"))
        #expect(!sdk.isShowing("RUNNING RULE (threshold not reached)"))
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_canvas_config.swift:81
    // `let remainingSeconds = (max(0, remainingMs) + 999) / 1_000` -> `let remainingSeconds = max(0, remainingMs) / 1_000`
    @Test("half a second above the threshold it is still running")
    func aboveTheThresholdItIsRunning() async throws {
        let sdk = try await showTimer(
            "inline_timer_urgent_threshold_boundary",
            clockAt: Self.deadline.addingTimeInterval(-186_313.5))
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the running rule is on screen") {
            sdk.isShowing("RUNNING RULE (threshold not reached)")
        }
        #expect(!sdk.isShowing("Hurry: last chance (first urgent rule)"))
    }

    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_canvas_config.swift:144
    // `else { continue }` (a rule for an unknown state) -> `else { return nil }`
    @Test("before its start a timer shows the fallback, never a rule for an unknown state or one written after the fallback")
    func beforeItsStartTheFallbackShows() async throws {
        let sdk = try await showTimer(
            "inline_timer_teaser_fallback_rules", clockAt: inlineUTC("2029-12-29T00:00:00Z"))
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the fallback rule is on screen") {
            sdk.isShowing("Sale starts soon (fallback rule)")
        }
        #expect(!sdk.isShowing("UNKNOWN STATE RULE (must be skipped)"))
        #expect(!sdk.isShowing("TEASER RULE AFTER FALLBACK (must never show)"))
    }

    /// The deadline is `2029-12-31 18:30:00.123456+05:30` (13:00 UTC) and the start a JS `Date`
    /// string, the formats the dashboard writes; the clock reads 2029-12-30 10:00 UTC, so 1 d 3 h
    /// are left. Ignoring the offset would leave 8 h.
    ///
    /// Flutter reads both from the variables' authored `fallbackValue`s when the trigger sends
    /// none. Known gap: iOS resolves timer instants from the trigger's variables only
    /// (`TimerInstantSource.resolve` reads `payload.variables`, never the schema fallbacks), and
    /// keeps the fixture's `"  sale_ends  "` token untrimmed, so the slot stays empty. The second
    /// half sends the same instants from the trigger, under the token exactly as authored; it is the offset
    /// parsing this test is for, and it holds on iOS.
    // Fails if: Sources/DigiaEngage/api/internal/campaign/inline_canvas_config.swift:224
    // `let offsetSeconds = (hours * 3_600 + minutes * 60) * (offset.first == "-" ? -1 : 1)` -> `let offsetSeconds = 0`
    @Test("dashboard date formats are read, offset and all, from the trigger variables")
    func dashboardDateFormatsAreRead() async throws {
        let clock = inlineUTC("2029-12-30T10:00:00Z")
        do {
            let sdk = try await showTimer("inline_timer_variable_instant_formats", clockAt: clock)
            defer { sdk.tearDown() }
            try await sdk.settle(0.5)
            withKnownIssue("iOS does not fall back to a timer variable's fallbackValue, nor trim its token") {
                #expect(sdk.isShowing("Variable deadline: 1 day left, not 2"))
            }
        }

        let sdk = try await showTimer(
            "inline_timer_variable_instant_formats",
            clockAt: clock,
            variables: [
                "  sale_ends  ": "2029-12-31 18:30:00.123456+05:30",
                "sale_starts": "Sat Dec 01 2029 10:00:00 GMT+0000 (Coordinated Universal Time)",
            ])
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the running rule is on screen") {
            sdk.isShowing("Variable deadline: 1 day left, not 2")
        }
        #expect(showsExactly(sdk, "03"), "1 d 3 h left; ignoring the +05:30 offset would read 8 h")
    }

    /// Delivers `inline_timer_variable_deadline_missing_shows_nothing` through the whole SDK — a
    /// bundle carrying the server clock, CEP delivery, routing — and opens its slot.
    private func deliverTimer(variables: [String: String]? = nil) async throws -> (SdkHarness, CampaignPresentation) {
        let json = try fixture("inline_timer/inline_timer_variable_deadline_missing_shows_nothing")
        let sdk = try SdkHarness.create(campaigns: [json])
        let serverTime = inlineUTC("2029-12-30T00:00:00Z")
        sdk.bundleHeaders = ["X-Digia-Server-Time-Ms": "\(Int64(serverTime.timeIntervalSince1970 * 1000))"]
        try await sdk.initialize()
        try sdk.requireReady()
        try await sdk.attachCep()
        let slot = try #require((json["templateConfig"] as? [String: Any])?["slotKey"] as? String)
        _ = try sdk.mountInlineSlot(slot)
        let delivery = try sdk.deliver(keyOf(json), variables: variables)
        try await sdk.settle(0.7)
        return (sdk, delivery)
    }

    // Fails if: Sources/DigiaEngage/api/internal/SDKInstance.swift:1680
    // `if let runtime = cfg.statefulTimer, runtime.resolve(payload.variables) == nil {` -> `if false {`
    // (the slot then takes a campaign with no deadline instead of dropping it).
    @Test("a deadline variable the trigger did not supply shows nothing at all")
    func missingDeadlineShowsNothing() async throws {
        let (sdk, delivery) = try await deliverTimer()
        defer { sdk.tearDown() }

        #expect(!sdk.isShowing("must never show"))
        #expect(delivery.dropReason == .invalidConfig)
    }

    @Test("the same timer shows once the trigger supplies the deadline")
    func suppliedDeadlineShows() async throws {
        let (sdk, delivery) = try await deliverTimer(variables: ["sale_ends": "2030-01-01T00:00:00Z"])
        defer { sdk.tearDown() }

        try await sdk.waitUntil("the timer is on screen") { sdk.isShowing("must never show") }
        #expect(delivery.dropReason == nil)
    }
}
}
