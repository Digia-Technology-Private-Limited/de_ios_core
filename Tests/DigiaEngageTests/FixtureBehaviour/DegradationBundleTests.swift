import Foundation
import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A campaign the SDK cannot use must cost only itself. Each fixture under
/// `campaigns/degradation/` rides in a real campaign bundle, in front of a good neighbour
/// (`engine_surface_busy_first`), through the real fetch and parse path.
/// Port of `flutter/core/test/fixture_behaviour/degradation_bundle_test.dart`.
///
/// platform note: the rule fixtures (`degrade_engine_rule_*`) are not ported — this SDK has no
/// rule engine; a campaign is shown only by a CEP trigger. An unknown campaign type is dropped at
/// parse (Flutter keeps it as unsupported), so it is asserted as dropped here.
@Suite("Degradation: campaign bundle", .serialized, .tags(.integration, .behaviour, .contract))
@MainActor
struct DegradationBundleTests {

    private static let neighbourTitle = "First Nudge Holds The Surface"

    /// Fixtures the parser must drop, and what makes each one unusable. One guard each:
    ///   missing id/key/type  — `CampaignModel.fromJson` returns nil for that field
    ///   canvas version       — the canvas parser's version window
    ///   outside tap          — the guide parser rejects the removed `dismiss` value
    ///   anchorless version   — the guide parser's anchorless target `> 1` guard
    nonisolated static let dropped: [String] = [
        "degrade_engine_missing_id",
        "degrade_engine_missing_key",
        "degrade_engine_missing_type",
        "degrade_engine_unknown_type_alt_id",
        "degrade_nudge_canvas_version_older",
        "degrade_nudge_canvas_version_newer",
        "degrade_guide_removed_outside_tap_value",
        "degrade_guide_anchorless_target_version_newer",
    ]

    @Test("never reaches the store, and the campaign beside it still shows", arguments: dropped)
    func droppedCampaignCostsOnlyItself(name: String) async throws {
        let bad = try fixture("degradation/\(name)")
        let neighbour = try fixture("engine/engine_surface_busy_first")
        let sdk = try await SdkHarness.start(campaigns: [bad, neighbour])
        defer { sdk.tearDown() }
        try sdk.mount { Text("host app") }

        #expect(sdk.sdk.campaignStore.keys == [keyOf(neighbour)])
        if let badKey = bad["campaignKey"] as? String, !badKey.isEmpty {
            let lost = try sdk.deliver(badKey)
            #expect(lost.dropReason == .unknownCampaignKey)
        }
        try sdk.deliver(keyOf(neighbour))
        try await sdk.waitUntil("the neighbour is up") { sdk.isShowing(Self.neighbourTitle) }
    }

    // Fails if an unknown campaign type stops being reported: `CampaignModel.fromJson`'s default
    // branch must record `campaign_unsupported` with the type, so the drop is diagnosable.
    @Test("an unknown campaign type is reported as campaign_unsupported")
    func unknownTypeIsReported() async throws {
        let unknown = try fixture("degradation/degrade_engine_unknown_type_alt_id")
        let sdk = try await SdkHarness.start(campaigns: [unknown])
        defer { sdk.tearDown() }

        let unsupported = sdk.records.filter { $0.reason?.wire == TimelineReason.campaignUnsupported.wire }
        #expect(unsupported.count == 1)
    }

    // A timer is also dropped when the response carries no server clock, so the version guard is
    // only visible when the bundle brings one. The control is the same timer shape at version 1,
    // which must reach the store. Fails if the timer's `stateful` version guard goes.
    @Test("degrade_inline_timer_version_too_new never reaches the store while the same timer at version 1 does")
    func timerVersionTooNew() async throws {
        let tooNew = try fixture("degradation/degrade_inline_timer_version_too_new")
        var current = tooNew
        current["id"] = "\(tooNew["id"] as? String ?? "")-control"
        current["campaignKey"] = "\(keyOf(tooNew))_control"
        var template = try #require(tooNew["templateConfig"] as? [String: Any])
        var stateful = try #require(template["stateful"] as? [String: Any])
        stateful["version"] = 1
        template["stateful"] = stateful
        current["templateConfig"] = template
        let neighbour = try fixture("engine/engine_surface_busy_first")

        let sdk = try SdkHarness.create(campaigns: [tooNew, current, neighbour])
        defer { sdk.tearDown() }
        let serverTime = ISO8601DateFormatter().date(from: "2029-01-01T00:00:00Z")!
        sdk.bundleHeaders = ["X-Digia-Server-Time-Ms": "\(Int64(serverTime.timeIntervalSince1970 * 1000))"]
        try await sdk.initialize()
        try sdk.requireReady()

        #expect(sdk.sdk.campaignStore.keys == [keyOf(current), keyOf(neighbour)].sorted())
    }

    // Fails if an unusable screen list starts hiding the campaign: the parsed list is used as a
    // restriction although it names no usable screen.
    @Test("a screen list of the wrong shape leaves the campaign untargeted")
    func wrongShapeScreenListLeavesCampaignUntargeted() async throws {
        try await expectShownOnUnnamedScreen("degrade_engine_screens_wrong_shape")
    }

    /// `["", " ", 7, null, true]`. Known gap: iOS keeps the blank `" "` as a screen name (it drops
    /// only empty strings; Flutter trims and drops blanks), so the campaign is restricted to a
    /// screen that can never be current and is dropped as `screen_not_targeted` everywhere.
    /// `withKnownIssue` fails the day iOS trims, as the cue to drop the wrapper.
    @Test("a screen list with no usable name leaves the campaign untargeted")
    func unusableNamesLeaveCampaignUntargeted() async throws {
        await withKnownIssue("iOS keeps a whitespace-only screen name as a target") {
            try await expectShownOnUnnamedScreen("degrade_engine_screens_unusable_names")
        }
    }

    private func expectShownOnUnnamedScreen(_ name: String) async throws {
        let campaign = try fixture("degradation/\(name)")
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        try sdk.mount { Text("host app") }
        sdk.setCurrentScreen("brands")

        let delivery = try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntil("the nudge is up") { sdk.sdk.controller.activeNudge != nil }

        #expect(delivery.dropReason == nil)
        #expect(sdk.sdk.controller.activeNudge?.payload.campaignKey == keyOf(campaign))
    }

    // Fails if a carousel item without an image is kept, or a legacy deepLink outranks
    // `onClick`: in `inline_carousel_config.swift` the `nonBlankString("imageUrl")` guard is
    // dropped, or the `onClick ?? deepLink` precedence is swapped.
    @Test("a legacy carousel drops only its image-less item and lets onClick win over deepLink")
    func legacyCarouselItems() async throws {
        let carousel = try fixture("degradation/degrade_inline_carousel_legacy_items_and_sizing")
        let sdk = try await SdkHarness.start(carousel)
        defer { sdk.tearDown() }

        let campaign = try #require(sdk.sdk.campaignStore.find(keyOf(carousel)))
        guard case .inline(let config) = campaign.config else {
            Issue.record("expected a legacy carousel, got \(campaign.config)")
            return
        }
        #expect(config.items.count == 3)
        #expect(config.items[0].actions == [.openDeeplink("digia-test://brands")])
        #expect(config.items[1].actions == [.openDeeplink("digia-test://offers")])
        #expect(config.items[2].actions.isEmpty)
    }
}
}
