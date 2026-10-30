import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension DigiaEngageTests {
    @MainActor
    @Suite("DigiaSlot component", .serialized)
    struct DigiaSlotTests {
        private var sdk: SDKInstance { SDKInstance.shared }

        private func deliver(_ campaignKey: String, _ cepCampaignId: String) -> PresentationRecorder {
            PresentationRecorder(
                sdk.deliver(
                    CEPTriggerPayload(cepCampaignId: cepCampaignId, campaignKey: campaignKey, cepMetadata: [:])
                )
            )
        }

        private func start(_ campaigns: [[String: Any]]) throws {
            sdk.resetForTesting()
            sdk.setCampaignsForTesting(try campaigns.map { try #require(try CampaignModel.fromJson($0)) })
        }

        private func makeWindow() -> UIWindow {
            let window = ComponentTestHost.makeWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.isHidden = false
            return window
        }

        private func settle() async {
            for _ in 0..<5 {
                await Task.yield()
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        @Test("a mounted slot impresses the same CEP campaign ID again after a clear")
        func slotRerendersSameCepCampaignIdAfterClear() async throws {
            try start([inlineJson("slot-test", slotKey: "slot_test")])

            let window = makeWindow()
            let slot = DigiaSlot("slot_test")
            let host = UIHostingController(rootView: slot)
            window.rootViewController = host
            window.addSubview(host.view)
            host.view.frame = window.bounds

            // Deliver first presentation
            let first = deliver("slot-test", "same-cep-id")
            await settle()

            #expect(first.displayed)
            #expect(first.presentation.state == .displaying)

            // Clear the slot
            sdk.clearInlineContent(["slot_test"])
            await settle()

            #expect(first.isSettled)
            #expect(first.dismissReason == .userClose)

            // Deliver second presentation with SAME cepCampaignId
            let second = deliver("slot-test", "same-cep-id")
            await settle()

            #expect(second.displayed)
            #expect(second.presentation.state == .displaying)

            // Clear again
            sdk.clearInlineContent(["slot_test"])
            await settle()

            #expect(second.isSettled)
            #expect(second.dismissReason == .userClose)
            #expect(second.dropReason == nil)

            window.rootViewController = nil
            host.view.removeFromSuperview()
        }
    }
}
