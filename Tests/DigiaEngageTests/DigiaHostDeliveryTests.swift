import Foundation
import Testing

@testable import DigiaEngage

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

    @Test("a trigger before the bundle lands is held; a newer one supersedes it")
    func heldBeforeTheBundle() {
        SDKInstance.shared.resetForTesting()

        let first = deliver("anything", cepCampaignId: "cep-a")
        #expect(!first.isSettled)

        let second = deliver("anything", cepCampaignId: "cep-b")
        #expect(first.dropReason == .superseded)
        #expect(!second.isSettled)
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

}

private func hostNudgeCampaign(
    key: String,
    targetScreenNames: [String] = []
) -> CampaignModel? {
    CampaignModel.fromJson([
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
    CampaignModel.fromJson([
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
