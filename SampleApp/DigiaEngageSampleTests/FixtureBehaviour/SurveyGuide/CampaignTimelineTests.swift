import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// What a campaign creator reads on the "Campaign timeline" screen
/// (`DigiaCampaignTimelineView`) after the SDK has done something with their campaigns, driven
/// from the shared fixtures in `sdk_testing_fixtures/campaigns` (`engine/`, `degradation/`,
/// `canvas/`).
///
/// The timeline is the on-device buffer (`ScreenSink`) the SDK's own logger fills at every
/// decision, so nothing here builds a record: a fixture is served through the real SDK, delivered
/// the way a CEP would, and the screen is opened over the app the way the debug settings open it.
/// The proof is the sentence on the screen. Three things no fixture can produce (a symbol this
/// build has never heard of, a record with no reason, a clock with single digits) are checked
/// with a record put straight into the buffer.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_campaign_timeline_test.dart`. Not ported:
/// the rule-engine cases (`lower_priority`, `wait_cancelled`, audience-gated, a rule that could
/// not be read) — this SDK has no rule engine, a campaign shows only on a CEP trigger; and the
/// severity colours, which are SwiftUI shapes with nothing a test can read but pixels.
@Suite("Campaign timeline", .serialized, .tags(.integration, .behaviour))
@MainActor
struct CampaignTimelineTests {

    private static let weeklyKey = "test_engine_frequency_week_window_total_cap"

    /// Boots [paths] over a plain app with an empty timeline buffer.
    private func boot(_ paths: [String]) async throws -> SdkHarness {
        // The buffer outlives a test, and an earlier one's records would be read.
        ScreenSink.shared.clear()
        let sdk = try await SdkHarness.start(campaigns: paths.map { try loadCampaign($0) })
        try sdk.mount { Text("host app") }
        return sdk
    }

    private func finish(_ sdk: SdkHarness) {
        sdk.window?.rootViewController?.presentedViewController?.dismiss(animated: false)
        sdk.tearDown()
        ScreenSink.shared.clear()
    }

    /// Opens the timeline over the running app, as the debug settings do.
    private func openTimeline(_ sdk: SdkHarness) async throws {
        var root = try #require(sdk.window?.rootViewController)
        // Present over whatever is already presented (a nudge sheet, say).
        while let presented = root.presentedViewController { root = presented }
        let screen = UIHostingController(rootView: NavigationView { DigiaCampaignTimelineView() })
        screen.modalPresentationStyle = .fullScreen
        root.present(screen, animated: false)
        try await sdk.waitUntil("the timeline is open") { sdk.isShowing("Campaign timeline") }
        try await sdk.settle(0.3)
    }

    /// Where [text] is drawn, exactly.
    private func top(_ sdk: SdkHarness, _ text: String) throws -> CGFloat {
        try #require(sdk.frames(exactly: text).first, "\"\(text)\" on screen").minY
    }

    // Fails if: DigiaCampaignTimelineView.swift `TimelineEntry.group` builds a card's records
    // newest-first (`records: [record] + entries[existing].records` becomes
    // `entries[existing].records + [record]`).
    @Test("each trigger is a card titled with the campaign, its rows in the order they happened, and the newest card on top")
    func cardPerShowing() async throws {
        let sdk = try await boot(["campaigns/engine/engine_frequency_week_window_total_cap.json"])
        defer { finish(sdk) }
        try sdk.deliver(Self.weeklyKey)
        try await sdk.waitUntil("the nudge is up") { sdk.sdk.controller.activeNudge != nil }
        try await sdk.tap(id: "button")
        try await sdk.waitUntil("the nudge is gone") { sdk.sdk.controller.activeNudge == nil }
        // One a week: the second trigger is turned away.
        try sdk.deliver(Self.weeklyKey)
        try await sdk.settle()

        try await openTimeline(sdk)

        #expect(sdk.frames(exactly: Self.weeklyKey).count == 2, "one card per showing")
        // The first showing reads as a story, oldest first.
        let displayed = try top(sdk, "Displayed")
        let dismissed = try top(sdk, "Dismissed — a button closed it")
        #expect(displayed < dismissed)
        #expect(sdk.frames(exactly: "Delivered").count == 2)
        // The turned-away trigger arrived last, so its card is above.
        let capped = try top(sdk, "Not shown — frequency cap reached")
        #expect(capped < displayed)
    }

    // Fails if: DigiaCampaignTimelineView.swift `case "bundle_fetched": return
    // record.extras["count"].map { "(\($0))" }` returns nil.
    @Test("what happened to the app as a whole is a plain row, with the one detail worth showing")
    func appRows() async throws {
        let sdk = try await boot(["campaigns/engine/engine_frequency_week_window_total_cap.json"])
        defer { finish(sdk) }

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "Digia started").isEmpty)
        #expect(!sdk.frames(exactly: "Campaigns downloaded (1)").isEmpty)
        #expect(!sdk.frames(exactly: "Connected to your messaging platform (action-test)").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift loses the `"bundle_empty"` copy.
    @Test("a bundle with nothing live says so")
    func emptyBundle() async throws {
        let sdk = try await boot([])
        defer { finish(sdk) }

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "No campaigns are live right now").isEmpty)
    }

    /// Flutter taps an inline story card; here the click is a survey's "Start Survey"
    /// (`survey_welcome_backdrop_stepback`), which signals `clicked` with element `welcome_start`.
    // Fails if: DigiaCampaignTimelineView.swift `case "clicked": return
    // record.extras["elementId"].map { "\"\($0)\"" }` returns nil.
    @Test("a click names the element that was tapped")
    func clickNamesElement() async throws {
        let sdk = try await boot(["campaigns/survey/survey_welcome_backdrop_stepback.json"])
        defer { SDKInstance.shared.surveyOrchestrator.dismiss(); finish(sdk) }
        try await sdk.openSurvey("test_survey_welcome_backdrop_stepback", firstText: "Help Us Improve Digia")
        try await sdk.tapExact("Start Survey")
        try await sdk.waitUntil("the first question") { sdk.isShowing("How often do you shop with us?") }

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "Clicked \"welcome_start\"").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift loses the `"surface_busy"` copy.
    @Test("something else already holds the screen")
    func surfaceBusy() async throws {
        let first = try fixture("engine/engine_surface_busy_first")
        let second = try fixture("engine/engine_surface_busy_second")
        let sdk = try await boot(["campaigns/engine/engine_surface_busy_first.json",
                                  "campaigns/engine/engine_surface_busy_second.json"])
        defer { finish(sdk) }
        try sdk.deliver(keyOf(first))
        try await sdk.waitUntil("the first is up") { sdk.sdk.controller.activeNudge != nil }
        let turnedAway = try sdk.deliver(keyOf(second))
        try await sdk.settle()
        #expect(turnedAway.dropReason == .surfaceBusy)

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "Not shown — something else was already on screen").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift loses the `"screen_not_targeted"` copy.
    @Test("it is not one of the screens the campaign targets")
    func screenNotTargeted() async throws {
        let mismatch = try fixture("engine/engine_screen_targeting_mismatch")
        let sdk = try await boot(["campaigns/engine/engine_screen_targeting_mismatch.json"])
        defer { finish(sdk) }
        try sdk.deliver(keyOf(mismatch))
        try await sdk.settle()

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "Not shown — not one of this campaign's screens").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift `case "campaign_unsupported": return
    // record.extras["type"].map { "(\($0))" }` returns nil.
    @Test("a campaign the SDK cannot use is said to have been skipped, or not supported, each in words")
    func cannotUse() async throws {
        let sdk = try await boot([
            "campaigns/degradation/degrade_engine_missing_key.json",
            "campaigns/degradation/degrade_engine_unknown_type_alt_id.json",
            "campaigns/engine/engine_surface_busy_first.json",
        ])
        defer { finish(sdk) }

        try await openTimeline(sdk)

        #expect(!sdk.frames(exactly: "A campaign couldn't be read and was skipped").isEmpty)
        #expect(!sdk.frames(exactly: "This campaign type can't show in this app (hologram)").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift `case "unknown_design_token": return
    // record.extras["token"].map { "(\($0))" }` returns nil.
    @Test("a design token the bundle never shipped is named")
    func unknownDesignTokenNamed() async throws {
        let sdk = try await boot(["campaigns/canvas/canvas_design_tokens.json"])
        defer { finish(sdk) }

        try await openTimeline(sdk)

        let missing = "A design token is missing — using the authored value (color.missing)"
        // Several tokens are reported; scroll the list until this one is drawn, as a reader would.
        try await sdk.scrollUntilShowing(missing)
        #expect(!sdk.frames(exactly: missing).isEmpty)
    }

    // MARK: - Records the SDK itself does not emit

    /// A reason from a version of the SDK this screen predates.
    private struct FutureReason: DiagnosticReason {
        let wire: String
    }

    private func record(reason: DiagnosticReason? = nil, message: String = "developer sentence") -> TimelineRecord {
        let at = Calendar.current.date(from: DateComponents(year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 5))!
        return TimelineRecord(timestamp: at, severity: .debug, tag: "DIGIA", message: message,
                              stage: .gating, reason: reason, campaignKey: "hero")
    }

    private func showWith(_ record: TimelineRecord) async throws -> SdkHarness {
        let sdk = try await boot([])
        ScreenSink.shared.clear()
        ScreenSink.shared.emit(record)
        try await openTimeline(sdk)
        return sdk
    }

    // Fails if: DigiaCampaignTimelineView.swift `guard let copy = copy[wire] else { return wire }`
    // returns "".
    @Test("a symbol this build has never heard of is shown as it is")
    func unknownSymbolRaw() async throws {
        let sdk = try await showWith(record(reason: FutureReason(wire: "cooldown")))
        defer { finish(sdk) }

        #expect(!sdk.frames(exactly: "cooldown").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift `guard let wire = record.reason?.wire else {
    // return record.message }` returns "".
    @Test("a record with no reason says what the developer wrote")
    func noReasonShowsMessage() async throws {
        let sdk = try await showWith(record(message: "something happened"))
        defer { finish(sdk) }

        #expect(!sdk.frames(exactly: "something happened").isEmpty)
    }

    // Fails if: DigiaCampaignTimelineView.swift `clock` formats with `%d` instead of `%02d`.
    @Test("the time is hours, minutes and seconds, each two digits")
    func clockTwoDigits() async throws {
        let sdk = try await showWith(record(reason: FutureReason(wire: "x")))
        defer { finish(sdk) }

        #expect(!sdk.frames(exactly: "03:04:05").isEmpty)
    }
}
}
