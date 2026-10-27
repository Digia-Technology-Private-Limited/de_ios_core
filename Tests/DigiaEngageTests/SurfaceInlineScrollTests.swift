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
        private var sdk: SDKInstance { SDKInstance.shared }
        private let slotKey = "slot_feed"
        private let rows = 30
        private let rowHeight: CGFloat = 200

        private func deliver(_ campaignKey: String) -> PresentationRecorder {
            PresentationRecorder(
                sdk.deliver(
                    CEPTriggerPayload(cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:])
                )
            )
        }

        private func start() throws {
            sdk.resetForTesting()
            sdk.setCampaignsForTesting(try [
                inlineJson("feed-a", slotKey: slotKey),
                inlineJson("feed-b", slotKey: slotKey),
            ].map { try #require(try CampaignModel.fromJson($0)) })
        }

        /// Tall rows, the slot, more tall rows, in a window: the slot starts far below the first screen.
        private func showFeed() -> (UIWindow, UIHostingController<AnyView>) {
            let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
            let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let feed = ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<(rows * 2 + 1), id: \.self) { i in
                        if i == rows {
                            DigiaSlot(slotKey)
                        } else {
                            Text("row \(i)").frame(height: rowHeight)
                        }
                    }
                }
            }
            let host = UIHostingController(rootView: AnyView(feed))
            window.rootViewController = host
            window.isHidden = false
            return (window, host)
        }

        private func scrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
            return nil
        }

        private func scroll(_ host: UIHostingController<AnyView>, to y: CGFloat) async throws {
            let scroll = try #require(scrollView(in: host.view))
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            host.view.layoutIfNeeded()
            await settle()
        }

        private func settle() async {
            for _ in 0..<5 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        private func occupant() -> String? {
            sdk.inlineController.getCampaign(slotKey)?.campaignKey
        }

        // Fails if a seen campaign stops blocking once its slot scrolls away: `hasDisplayed:
        // events.hasImpressed(payload.cepCampaignId)` in SDKInstance.occupant (the impression, not the slot on
        // screen, is what counts).
        @Test("a campaign seen, then scrolled away, keeps its slot")
        func seenThenScrolledAwayKeepsItsSlot() async throws {
            try start()
            let (window, host) = showFeed()
            defer { window.isHidden = true; window.rootViewController = nil }
            await settle()

            let first = deliver("feed-a")
            await settle()
            #expect(!first.displayed, "the slot is not built yet")
            try await scroll(host, to: CGFloat(rows) * rowHeight - rowHeight)
            #expect(first.displayed, "the first is drawn once scrolled to")

            try await scroll(host, to: 0)
            let second = deliver("feed-b")
            await settle()

            #expect(second.dropReason == .surfaceBusy)
            #expect(!first.isSettled, "the first still holds the slot")
            #expect(occupant() == "feed-a")
        }

        // Fails if an occupant counts as displayed without an impression: `hasDisplayed:
        // events.hasImpressed(payload.cepCampaignId)` in SDKInstance.occupant, e.g. replaced by "the slot holds
        // a campaign".
        @Test("a campaign whose slot was never built is superseded by the next")
        func neverBuiltIsSuperseded() async throws {
            try start()
            let (window, host) = showFeed()
            defer { window.isHidden = true; window.rootViewController = nil }
            await settle()

            let first = deliver("feed-a")
            await settle()
            let second = deliver("feed-b")
            await settle()

            #expect(first.dropReason == .superseded)
            #expect(!second.isSettled, "the second holds the slot")
            #expect(occupant() == "feed-b")
            try await scroll(host, to: CGFloat(rows) * rowHeight - rowHeight)
            #expect(second.displayed, "the second is drawn once scrolled to")
        }
    }
}
