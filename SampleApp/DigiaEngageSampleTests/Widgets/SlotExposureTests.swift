import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// A carousel slot counts a slide as viewed only while the slot is exposed (`SlotExposure.swift`):
/// at least half of it inside every clipping ancestor and the window, with the app active. The
/// slot sits below the fold of the app's scroll view, and the proof is the `Digia Step Viewed`
/// event the backend receives. Fixture: `inline_carousel_indicators/inline_carousel_indicators_scrolling`
/// (seven slides, no autoplay, slot `home_featured_carousel`).
///
/// Port of `flutter/core/test/slot_exposure_test.dart`'s scroll cases. iOS differs by design:
/// Flutter's `SlotExposure` reports every appearance (for `slot_visible` / `anchor_visible`);
/// iOS's gate only drives carousel steps and keeps one gate per slot, so scrolling the same slide
/// back into view is quiet. Not ported: the route and dialog cases (`throughPopups`), which belong
/// to Flutter's navigator; iOS has no `slot_visible` exposure event.
@Suite("Slot exposure", .serialized, .tags(.integration, .inline))
@MainActor
struct SlotExposureTests {

    private static let slotKey = "home_featured_carousel"

    private func stepsViewed(_ sdk: SdkHarness, _ key: String) async throws -> [[String: Any]] {
        try await sdk.events()
            .filter { $0["campaign_key"] as? String == key && $0["event_name"] as? String == "Digia Step Viewed" }
            .map { $0["properties"] as? [String: Any] ?? [:] }
    }

    private func scrollView(_ sdk: SdkHarness) throws -> UIScrollView {
        let window = try #require(sdk.window)
        var found: UIScrollView?
        SdkHarness.widgetsCollect(in: window, where: { $0 is UIScrollView }) { found = found ?? ($0 as? UIScrollView) }
        return try #require(found)
    }

    // Fails if: SlotExposure.swift `observeAncestorScrollViews` stops observing the scroll view's
    // `contentOffset` (the slot would never learn it scrolled into view), or `isHalfVisible` stops
    // clipping to the window (the slot below the fold would count as seen).
    @Test("a carousel below the fold counts its slide viewed only once scrolled into view, and not again on returning")
    func belowTheFoldCountsOnScroll() async throws {
        let campaign = try fixture("inline_carousel_indicators/inline_carousel_indicators_scrolling")
        let key = keyOf(campaign)
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        try sdk.mount {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1500)
                    DigiaSlot(Self.slotKey)
                    Color.clear.frame(height: 3000)
                }
            }
        }
        try sdk.deliver(key)
        try await sdk.waitUntil("the carousel in its slot") {
            SDKInstance.shared.inlineController.getCampaign(Self.slotKey) != nil
        }
        try await sdk.settle(1.0)
        #expect(try await stepsViewed(sdk, key).isEmpty, "nothing seen below the fold")

        let scroll = try scrollView(sdk)
        scroll.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        var viewed: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(5)
        while viewed.isEmpty, Date() < deadline { viewed = try await stepsViewed(sdk, key) }
        #expect(viewed.count == 1)
        #expect(viewed.first?["item_index"] as? Int == 1)

        // Out of view and back: the same slide, already counted.
        scroll.setContentOffset(.zero, animated: false)
        try await sdk.settle(0.5)
        scroll.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        try await sdk.settle(0.5)
        #expect(try await stepsViewed(sdk, key).count == 1)
    }

    // Fails if: SlotExposure.swift `isHalfVisible` stops honouring a hidden ancestor
    // (`if view.isHidden || view.alpha < 0.01 { return false }`).
    @Test("a carousel in a transparent part of the app is not seen until it shows")
    func hiddenAncestorIsNotExposed() async throws {
        let campaign = try fixture("inline_carousel_indicators/inline_carousel_indicators_scrolling")
        let key = keyOf(campaign)
        let sdk = try await SdkHarness.start(campaign)
        defer { sdk.tearDown() }
        let state = SlotExposureOpacity()
        try sdk.mount { SlotExposureFadingHost(state: state, slotKey: Self.slotKey) }
        try sdk.deliver(key)
        try await sdk.waitUntil("the carousel in its slot") {
            SDKInstance.shared.inlineController.getCampaign(Self.slotKey) != nil
        }
        try await sdk.settle(1.0)
        #expect(try await stepsViewed(sdk, key).isEmpty, "nothing seen while transparent")

        state.opacity = 1
        // A container fading in moves no frame; the slot learns of it on its next layout pass.
        // Nudged on every poll: a single nudge can land before the fade has reached the layer.
        let scroll = try scrollView(sdk)
        var viewed: [[String: Any]] = []
        var nudge: CGFloat = 1
        let deadline = Date().addingTimeInterval(5)
        while viewed.isEmpty, Date() < deadline {
            scroll.setContentOffset(CGPoint(x: 0, y: nudge), animated: false)
            nudge = nudge == 1 ? 0 : 1
            viewed = try await stepsViewed(sdk, key)
        }
        #expect(viewed.count == 1)
    }
}
}

@MainActor
final class SlotExposureOpacity: ObservableObject {
    @Published var opacity: Double = 0
}

/// The slot inside a scroll view whose content starts transparent.
private struct SlotExposureFadingHost: View {
    @ObservedObject var state: SlotExposureOpacity
    let slotKey: String

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                DigiaSlot(slotKey)
                Color.clear.frame(height: 2000)
            }
            .opacity(state.opacity)
        }
    }
}
