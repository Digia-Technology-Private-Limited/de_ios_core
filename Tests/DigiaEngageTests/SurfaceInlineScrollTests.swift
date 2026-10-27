import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension DigiaEngageTests {
    /// SR05 for a slot inside a scrolling list (surface-rule-plan §2.1): "displayed" means the slot's campaign
    /// produced an impression, not that the slot is on screen now. A `LazyVStack` builds a row only near the
    /// viewport and lets it go once scrolled away, so the slot view cannot remember it was seen; the SDK does.
    ///
    /// A campaign that was seen keeps its slot after the slot scrolls away. A campaign delivered while its slot
    /// was never built gave no impression, so the next campaign for that slot supersedes it.
    @MainActor
    @Suite("SR05 inline slot in a scrolling list", .serialized)
    struct SurfaceInlineScrollTests {
        private static let slotKey = "slot_feed"
        private let rows = 30
        private let rowHeight: CGFloat = 200

        private func start() async throws -> SdkHarness {
            try await SdkHarness.start(
                inlineJson("feed-a", slotKey: Self.slotKey),
                inlineJson("feed-b", slotKey: Self.slotKey))
        }

        /// Tall rows, the slot, more tall rows: the slot starts far below the first screen.
        private func showFeed(_ sdk: SdkHarness) throws {
            try sdk.mount {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<(rows * 2 + 1), id: \.self) { i in
                            if i == rows {
                                DigiaSlot(Self.slotKey)
                            } else {
                                Text("row \(i)").frame(height: rowHeight)
                            }
                        }
                    }
                }
            }
        }

        private func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
            return nil
        }

        private func scroll(_ sdk: SdkHarness, to y: CGFloat) async throws {
            let window = try #require(sdk.window)
            let scroll = try #require(scrollView(in: window))
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            window.layoutIfNeeded()
            await sdk.settle()
        }

        private func occupant() -> String? {
            SDKInstance.shared.inlineController.getCampaign(Self.slotKey)?.campaignKey
        }

        private func dropReason(_ outcome: PresentationOutcome?) -> DropReason? {
            if case .dropped(let reason, _) = outcome { return reason }
            return nil
        }

        // Fails if a seen campaign stops blocking once its slot scrolls away: `hasDisplayed:
        // events.hasImpressed(payload.cepCampaignId)` in SDKInstance.occupant (the impression, not the slot on
        // screen, is what counts).
        @Test("a campaign seen, then scrolled away, keeps its slot")
        func seenThenScrolledAwayKeepsItsSlot() async throws {
            let sdk = try await start()
            defer { sdk.tearDown() }
            try showFeed(sdk)

            let first = try sdk.deliver("feed-a")
            // The harness reports outcomes; the `.displayed` signal is read through the recorder.
            let firstSignals = PresentationRecorder(first)
            await sdk.settle()
            #expect(!firstSignals.displayed, "the slot is not built yet")
            try await scroll(sdk, to: CGFloat(rows) * rowHeight - rowHeight)
            #expect(firstSignals.displayed, "the first is drawn once scrolled to")

            try await scroll(sdk, to: 0)
            let second = try sdk.deliver("feed-b")
            await sdk.settle()

            #expect(dropReason(sdk.outcome(of: second)) == .surfaceBusy)
            #expect(sdk.outcome(of: first) == nil, "the first still holds the slot")
            #expect(occupant() == "feed-a")
        }

        // Fails if an occupant counts as displayed without an impression: `hasDisplayed:
        // events.hasImpressed(payload.cepCampaignId)` in SDKInstance.occupant, e.g. replaced by "the slot holds
        // a campaign".
        @Test("a campaign whose slot was never built is superseded by the next")
        func neverBuiltIsSuperseded() async throws {
            let sdk = try await start()
            defer { sdk.tearDown() }
            try showFeed(sdk)

            let first = try sdk.deliver("feed-a")
            await sdk.settle()
            let second = try sdk.deliver("feed-b")
            let secondSignals = PresentationRecorder(second)
            await sdk.settle()

            #expect(dropReason(sdk.outcome(of: first)) == .superseded)
            #expect(sdk.outcome(of: second) == nil, "the second holds the slot")
            #expect(occupant() == "feed-b")
            try await scroll(sdk, to: CGFloat(rows) * rowHeight - rowHeight)
            #expect(secondSignals.displayed, "the second is drawn once scrolled to")
        }
    }
}
