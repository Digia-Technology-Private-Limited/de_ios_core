import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: these reset SDKInstance.shared.
extension DigiaEngageTests {
    /// The `setCampaignsSuppressed` contract (`campaign-suppression`, issue #154):
    /// while the host suppresses overlays, an overlay delivery drops as
    /// `host_suppressed` with its CEP hold released, inline keeps rendering,
    /// and unsuppressing restores overlays.
    @MainActor
    @Suite("Campaign suppression", .serialized, .tags(.integration, .surface, .cep))
    struct CampaignSuppressionTests {
        private var sdk: SDKInstance { SDKInstance.shared }

        private func deliver(
            _ campaignKey: String,
            cepCampaignId: String = "cep-1",
            cepMetadata: [String: String] = [:]
        ) -> PresentationRecorder {
            PresentationRecorder(
                sdk.deliver(
                    CEPTriggerPayload(
                        cepCampaignId: cepCampaignId,
                        campaignKey: campaignKey,
                        cepMetadata: cepMetadata
                    )
                )
            )
        }

        private func start(_ campaigns: [[String: Any]]) throws {
            sdk.resetForTesting()
            sdk.setCampaignsForTesting(try campaigns.map { try #require(try CampaignModel.fromJson($0)) })
        }

        private func freshInitializedInstance() async throws -> SDKInstance {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            return sdk
        }

        @Test("while suppressed, an overlay delivery drops host_suppressed and releases the hold")
        func suppressedOverlayDropsAndReleases() throws {
            try start([nudgeJson("n")])
            defer { sdk.setCampaignsSuppressed(false) }
            sdk.setCampaignsSuppressed(true)

            let dropped = deliver("n")

            #expect(dropped.isSettled)
            #expect(dropped.dropReason == .hostSuppressed)
            // The critical invariant: the drop settles together with the hold,
            // or the CEP's queue jams behind a slot nobody owns.
            #expect(dropped.isHoldReleased)
            #expect(sdk.controller.activeNudge == nil)
        }

        @Test("while suppressed, an inline delivery still gets through")
        func suppressedInlineStillRenders() throws {
            try start([inlineJson("i", slotKey: "home_hero")])
            defer { sdk.setCampaignsSuppressed(false) }
            sdk.setCampaignsSuppressed(true)

            let inline = deliver("i")

            // Accepted, so still pending: a drop would have settled at once.
            #expect(!inline.isSettled)
            #expect(inline.isHoldReleased)
        }

        @Test("after unsuppressing, an overlay delivery is accepted again")
        func unsuppressRestoresOverlays() throws {
            try start([nudgeJson("n")])
            sdk.setCampaignsSuppressed(true)

            let dropped = PresentationRecorder(sdk.triggerCampaign("n", variables: nil))
            #expect(dropped.dropReason == .hostSuppressed)

            sdk.setCampaignsSuppressed(false)
            let restored = PresentationRecorder(sdk.triggerCampaign("n", variables: nil))

            #expect(!restored.isSettled)
            #expect(sdk.controller.activeNudge?.payload.campaignKey == "n")
        }

        @Test("an unknown key while suppressed is still unknown_campaign_key")
        func unknownKeyBeatsSuppression() throws {
            try start([nudgeJson("known")])
            defer { sdk.setCampaignsSuppressed(false) }
            sdk.setCampaignsSuppressed(true)

            #expect(deliver("not-known").dropReason == .unknownCampaignKey)
        }

        @Test("a broken config while suppressed is still invalid_config")
        func invalidConfigBeatsSuppression() throws {
            try start([floaterJson("pip")])
            defer { sdk.setCampaignsSuppressed(false) }
            sdk.setCampaignsSuppressed(true)

            // A floater delivered as a CleverTap custom template is a router-level
            // config error, checked before the suppression gate.
            let dropped = deliver("pip", cepMetadata: ["templateName": "DigiaTemplate"])

            #expect(dropped.dropReason == .invalidConfig)
            #expect(dropped.isHoldReleased)
        }

        @Test("a suppressed trigger never consumes a frequency cap")
        func suppressedTriggerSkipsFrequencyCap() async throws {
            let sdk = try await freshInitializedInstance()
            var once = nudgeJson("once")
            once["frequency"] = ["maxTotal": 1]
            sdk.setCampaignsForTesting([try #require(try CampaignModel.fromJson(once))])
            let deliver: (String) -> PresentationRecorder = { key in
                PresentationRecorder(
                    sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-\(key)", campaignKey: key, cepMetadata: [:])))
            }

            sdk.setCampaignsSuppressed(true)
            #expect(deliver("once").dropReason == .hostSuppressed)
            sdk.setCampaignsSuppressed(false)

            // The suppressed drop above must not have spent the single impression.
            let shown = deliver("once")
            #expect(!shown.isSettled)
            sdk.reportNudgeImpression()
            sdk.markNudgeDismissed()

            // ...which this cap proves is working: the real impression spent it.
            #expect(deliver("once").dropReason == .frequencyCapped)
        }

        @Test("suppression set before initialize() is honoured once ready")
        func suppressionBeforeInitializeIsHonoured() async throws {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            sdk.setCampaignsSuppressed(true)
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            sdk.setCampaignsForTesting([try #require(try CampaignModel.fromJson(nudgeJson("n")))])

            let dropped = PresentationRecorder(
                sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-1", campaignKey: "n", cepMetadata: [:])))

            #expect(dropped.dropReason == .hostSuppressed)
            #expect(dropped.isHoldReleased)
        }
    }
}
