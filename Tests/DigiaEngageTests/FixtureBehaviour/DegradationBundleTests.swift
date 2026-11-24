import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A campaign the SDK cannot use must cost only itself. Each fixture under
/// `campaigns/degradation/` rides in a real campaign bundle, in front of a good neighbour
/// (`engine_surface_busy_first`), through the real fetch and parse path.
/// Port of `flutter/core/test/fixture_behaviour/degradation_bundle_test.dart`.
///
/// platform note: the rule fixtures (`degrade_engine_rule_*`) are not ported here; the rule engine
/// has its own suites. An unknown campaign type is kept in the store as unsupported, as Flutter does.
@Suite("Degradation: campaign bundle", .serialized, .tags(.integration, .behaviour, .contract))
@MainActor
struct DegradationBundleTests {

    // The never-reaches-the-store, unknown-type and timer-version cases moved
    // to testkit/sdk-tests/tests/degradation/d01-d03, d08. What stays here
    // fails in YAML on iOS: the unusable screen lists (#242) and the legacy
    // carousel (legacy UI, out of scope).

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
