import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// What a tap on an inline banner does. `inline_banner/inline_banner_home` carries an open-URL
/// action (`digia-test://offers`, `platformDefault`, so a deep link);
/// `inline_banner/inline_banner_fixed_height_contain` carries none. Every tap is a real touch on
/// the banner the SDK rendered in the app's `DigiaSlot`, and the proof is what the host's
/// handlers are asked to do and which click the SDK reports.
///
/// The banner pictures are CDN images; the banner takes taps whether or not they have loaded
/// (its tap area is its frame, `DigiaInlineBannerView`), so nothing here waits for them.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_banner_test.dart`.
@Suite("Inline banner: tap", .serialized,
       .tags(.integration, .behaviour, .inline))
@MainActor
struct InlineBannerTapTests {

    private struct Tapped {
        let deepLinks: [String]
        let urls: [String]
        let opened: [String]
        let clicks: [[String: Any]]
    }

    private func tapBanner(_ path: String, slot: String) async throws -> Tapped {
        let campaign = try fixture(path)
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        let deepLinks = Received<String>()
        let urls = Received<String>()
        sdk.setDeepLinkHandler { deepLinks.append($0) }
        sdk.setOpenURLHandler { urls.append($0) }
        let probe = NudgeCanvasFrameProbe()
        try sdk.mount {
            VStack(spacing: 0) {
                DigiaSlot(slot) { EmptyView() }.nudgeCanvasFrame(probe)
                Spacer()
            }
        }
        try sdk.deliver(keyOf(campaign))
        try await sdk.waitUntilSteady("the banner laid out") { probe.frame.height > 20 ? probe.frame : nil }

        try sdk.tap(at: CGPoint(x: probe.frame.midX, y: probe.frame.midY))
        try await sdk.settle(0.5)

        let clicks = try await sdk.events().filter {
            $0["campaign_key"] as? String == keyOf(campaign)
                && $0["event_name"] as? String == "Digia Experience Clicked"
        }
        return Tapped(
            deepLinks: deepLinks.values, urls: urls.values, opened: sdk.platform.opened, clicks: clicks)
    }

    // Fails if: DigiaInlineBannerView.swift `handleTap` stops calling
    // `SDKInstance.shared.reportBannerClicked` (no click) or `executeActionFlow` (no deep link).
    @Test("tapping a banner with an open-URL action hands the link to the host and reports one click")
    func bannerWithActionReportsOneClick() async throws {
        let tapped = try await tapBanner("inline_banner/inline_banner_home", slot: "home_banner")

        #expect(tapped.deepLinks == ["digia-test://offers"])
        #expect(tapped.urls.isEmpty)
        #expect(tapped.opened.isEmpty, "the host's handler took it, not iOS")
        #expect(tapped.clicks.count == 1)
        let properties = tapped.clicks.first?["properties"] as? [String: Any] ?? [:]
        #expect(properties["element_id"] as? String == "banner")
        #expect(properties["action_url"] as? String == "digia-test://offers")
    }

    // Fails if: DigiaInlineBannerView.swift attaches its `onTapGesture(perform: handleTap)` even
    // when `actions.isEmpty` (an action-less banner would report a click).
    @Test("tapping a banner with no action does nothing and reports no click")
    func actionlessBannerDoesNothing() async throws {
        let tapped = try await tapBanner(
            "inline_banner/inline_banner_fixed_height_contain", slot: "home_banner_fixed")

        #expect(tapped.deepLinks.isEmpty)
        #expect(tapped.urls.isEmpty)
        #expect(tapped.opened.isEmpty)
        #expect(tapped.clicks.isEmpty)
    }
}
}
