import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: these reset SDKInstance.shared.
extension DigiaEngageTests {
    /// The gate in front of the state machine: a handle comes back whatever the
    /// SDK's state, and each rejection settles it with the reason a plugin needs to
    /// release its slot. Where v1 answered one `false`, each of these is a
    /// different thing to fix.
    @MainActor
    @Suite("DigiaCEPHost delivery", .serialized)
    struct DigiaHostDeliveryTests {
        private func deliver(_ campaignKey: String, cepCampaignId: String = "cep-1")
            -> PresentationRecorder
        {
            PresentationRecorder(
                SDKInstance.shared.deliver(
                    CEPTriggerPayload(
                        cepCampaignId: cepCampaignId,
                        campaignKey: campaignKey,
                        cepMetadata: [:]
                    )
                )
            )
        }

        @Test("deliver is total — a handle comes back even with nothing to render")
        func deliverIsTotal() {
            SDKInstance.shared.resetForTesting()
            SDKInstance.shared.setCampaignsForTesting([])

            let recorder = deliver("nothing-here")

            #expect(recorder.presentation.id.isEmpty == false)
            #expect(recorder.isSettled)
            #expect(recorder.isHoldReleased)
        }

        @Test("a trigger before initialize() was ever called is dropped not_initialized at once")
        func droppedBeforeInitialize() {
            SDKInstance.shared.resetForTesting()

            let recorder = deliver("anything", cepCampaignId: "cep-a")
            #expect(recorder.isSettled)
            #expect(recorder.dropReason == .notInitialized)
            #expect(recorder.isHoldReleased)
            SDKInstance.shared.resetForTesting()
        }

        @Test("a key the store does not have is unknown_campaign_key")
        func unknownCampaignKey() throws {
            SDKInstance.shared.resetForTesting()
            SDKInstance.shared.setCampaignsForTesting([try #require(hostNudgeCampaign(key: "known"))])

            #expect(deliver("not-known").dropReason == .unknownCampaignKey)
        }

        @Test("a campaign scoped to another screen is screen_not_targeted")
        func screenNotTargeted() throws {
            SDKInstance.shared.resetForTesting()
            SDKInstance.shared.setCampaignsForTesting([
                try #require(hostNudgeCampaign(key: "help-only", targetScreenNames: ["Help"]))
            ])
            SDKInstance.shared.setCurrentScreen("Home")

            #expect(deliver("help-only").dropReason == .screenNotTargeted)
        }

        @Test("a second experience turned away by the incumbent is surface_busy")
        func surfaceBusy() throws {
            SDKInstance.shared.resetForTesting()
            SDKInstance.shared.setCampaignsForTesting([
                try #require(hostSurveyCampaign(key: "survey-a")),
                try #require(hostSurveyCampaign(key: "survey-b")),
            ])

            let incumbent = deliver("survey-a", cepCampaignId: "cep-a")
            let turnedAway = deliver("survey-b", cepCampaignId: "cep-b")

            #expect(!incumbent.isSettled)
            #expect(turnedAway.dropReason == .surfaceBusy)
            #expect(turnedAway.isHoldReleased)
        }

        @Test("the presentation id is minted through the injected generator, read late")
        func idGeneratorIsReadThrough() throws {
            SDKInstance.shared.resetForTesting()
            SDKInstance.shared.setCampaignsForTesting([try #require(hostNudgeCampaign(key: "n"))])
            // Set *after* the coordinator would have been built — capturing the
            // generator instead of reading it through is a seam that looks wired and
            // is not.
            var minted = 0
            SDKInstance.shared.idGenerator = {
                minted += 1
                return "fixed-\(minted)"
            }
            defer { SDKInstance.shared.idGenerator = { UUID().uuidString } }

            let recorder = deliver("n")

            #expect(recorder.presentation.id == "fixed-1")
            #expect(recorder.payload.presentationId == "fixed-1")
        }

        @Test("a resolved trigger sends Triggered, and Dropped with the same impression only if it drops")
        func deliveryEventsPairByImpression() async throws {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            sdk.setCampaignsForTesting([
                try #require(try CampaignModel.fromJson(nudgeJson("help-only", targetScreenNames: ["Help"]))),
                try #require(try CampaignModel.fromJson(nudgeJson("shown"))),
            ])
            sdk.setCurrentScreen("Home")
            let deliver = { (key: String) in
                PresentationRecorder(
                    sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-\(key)", campaignKey: key, cepMetadata: [:])))
            }

            let dropped = deliver("help-only")
            _ = deliver("not-in-bundle")
            let shown = deliver("shown")
            sdk.reportNudgeImpression()
            sdk.markNudgeDismissed()
            try? await Task.sleep(nanoseconds: 100_000_000)

            let events = try #require(sdk.services?.analyticsService).queue.peek(maxCount: 100)
                .map(\.payload)
                .filter { ["Digia Experience Triggered", "Digia Experience Dropped"].contains($0["event_name"] as? String) }
            let rows = events.map {
                [$0["event_name"] as? String, $0["campaign_key"] as? String, $0["impression_id"] as? String,
                 ($0["properties"] as? [String: Any])?["drop_reason"] as? String]
            }
            #expect(rows == [
                ["Digia Experience Triggered", "help-only", dropped.presentation.id, nil],
                ["Digia Experience Triggered", "shown", shown.presentation.id, nil],
                ["Digia Experience Dropped", "help-only", dropped.presentation.id, "screen_not_targeted"],
            ])
            let triggered = try #require(events.first)
            #expect(triggered["campaign_id"] as? String == "help-only-id")
            #expect((triggered["properties"] as? [String: Any])?["screen_name"] as? String == "Home")
        }

        // One instance for both reasons: every `initialize()` flips a process-wide
        // endpoint flag another (parallel) suite resets, so these share one.
        @Test("Dropped names the campaign that blocked it, and the frequency rule that capped it")
        func droppedCarriesPerReasonDetail() async throws {
            let sdk = try await initializedInstance()
            var once = nudgeJson("once")
            once["frequency"] = ["maxTotal": 1]
            sdk.setCampaignsForTesting([
                try #require(try CampaignModel.fromJson(once)),
                try #require(hostSurveyCampaign(key: "survey-a")),
                try #require(hostSurveyCampaign(key: "survey-b")),
            ])
            let deliver = { (key: String) in
                _ = sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-\(key)", campaignKey: key, cepMetadata: [:]))
            }
            deliver("once")
            sdk.reportNudgeImpression()
            sdk.markNudgeDismissed()
            deliver("once")
            deliver("survey-a")
            deliver("survey-b")
            try? await Task.sleep(nanoseconds: 100_000_000)

            let dropped = try droppedProperties(sdk)
            #expect(dropped.count == 2)
            let capped = try #require(dropped.first)
            #expect(capped["drop_reason"] as? String == "frequency_capped")
            #expect(capped["cap_rule"] as? String == "max_total")
            #expect(capped["cap_limit"] as? Int == 1)
            #expect(capped["cap_window"] == nil)
            let busy = try #require(dropped.last)
            #expect(busy["drop_reason"] as? String == "surface_busy")
            #expect(busy["blocking_campaign_key"] as? String == "survey-a")
            #expect(busy["blocking_campaign_id"] as? String == "survey-a-id")
            #expect(busy["blocking_kind"] as? String == "survey")
            #expect(busy["blocking_displayed"] as? Bool == false)
        }

        private func initializedInstance() async throws -> SDKInstance {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            return sdk
        }

        private func droppedProperties(_ sdk: SDKInstance) throws -> [[String: Any]] {
            try #require(sdk.services?.analyticsService).queue.peek(maxCount: 100)
                .map(\.payload)
                .filter { $0["event_name"] as? String == "Digia Experience Dropped" }
                .compactMap { $0["properties"] as? [String: Any] }
        }

    }
}

private func hostNudgeCampaign(
    key: String,
    targetScreenNames: [String] = []
) -> CampaignModel? {
    try? CampaignModel.fromJson([
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "nudge",
        "targetScreenNames": ["names": targetScreenNames],
        "templateConfig": [
            "container": ["displayType": "dialog"],
            "layout": ["type": "digia/column", "props": [:], "children": []],
        ],
    ])
}

private func hostSurveyCampaign(key: String) -> CampaignModel? {
    try? CampaignModel.fromJson([
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "survey",
        "templateConfig": [
            "templateType": "survey",
            "blocks": [
                [
                    "id": "block-1",
                    "type": "single_select",
                    "title": ["text": "How are you?"],
                    "options": [
                        ["id": "opt_a", "label": "Good"],
                        ["id": "opt_b", "label": "Bad"],
                    ],
                ],
            ],
            "nodes": [["id": "node-1", "blockId": "block-1"]],
        ],
    ])
}
