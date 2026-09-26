import Foundation
import Testing

@testable import DigiaEngage

/// The surface rule wired into routing (plan SR04–SR06), end to end through
/// `deliver` and the live-test handler.
@MainActor
@Suite("Surface rule routing", .serialized)
struct SurfaceRoutingTests {
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
        sdk.setCampaignsForTesting(try campaigns.map { try #require(CampaignModel.fromJson($0)) })
    }

    private func liveTest(_ invocationId: String, _ campaign: [String: Any]) {
        sdk.handleLiveTestCampaign(
            LiveTestInvocation(
                testInvocationId: invocationId, campaignId: "id", campaign: campaign, variables: [:]))
    }

    // MARK: - Organic

    @Test("nudge over nudge → surface_busy, the first stays")
    func nudgeOverNudge() throws {
        try start([nudgeJson("n1"), nudgeJson("n2")])
        let first = deliver("n1", "cep-1")
        let second = deliver("n2", "cep-2")

        #expect(!first.isSettled)
        #expect(second.dropReason == .surfaceBusy)
        #expect(sdk.controller.activeNudge?.payload.campaignKey == "n1")
    }

    @Test("guide over a collapsed floater → shows")
    func guideOverCollapsedFloater() throws {
        try start([floaterJson("pip"), guideJson("g")])
        let floater = deliver("pip", "cep-f")
        try #require(sdk.floaterOrchestrator.state != nil)
        try #require(sdk.floaterOrchestrator.surface == .collapsed)

        let guide = deliver("g", "cep-g")

        #expect(!floater.isSettled)
        #expect(!guide.isSettled)
        #expect(sdk.guideOrchestrator.state?.payload.campaignKey == "g")
    }

    @Test("a collapsed floater cannot expand under a nudge (SR07)")
    func floaterCannotExpandUnderNudge() throws {
        try start([floaterJson("pip"), nudgeJson("n")])
        _ = deliver("pip", "cep-f")
        _ = deliver("n", "cep-n")
        try #require(sdk.controller.activeNudge != nil)

        sdk.floaterOrchestrator.expand()
        #expect(sdk.floaterOrchestrator.surface == .collapsed)

        sdk.markNudgeDismissed()
        sdk.floaterOrchestrator.expand()
        #expect(sdk.floaterOrchestrator.surface == .expanded)
    }

    @Test("floater over a collapsed floater → surface_busy")
    func floaterOverCollapsedFloater() throws {
        try start([floaterJson("pip1"), floaterJson("pip2")])
        let first = deliver("pip1", "cep-1")
        try #require(sdk.floaterOrchestrator.state != nil)

        let second = deliver("pip2", "cep-2")

        #expect(!first.isSettled)
        #expect(second.dropReason == .surfaceBusy)
    }

    @Test("inline, same slot, never displayed → replaced, the old one superseded")
    func inlineSameSlotNeverDisplayed() throws {
        try start([inlineJson("i1"), inlineJson("i2")])
        let first = deliver("i1", "cep-1")
        let second = deliver("i2", "cep-2")

        #expect(first.dropReason == .superseded)
        #expect(first.isHoldReleased)
        #expect(!second.isSettled)
        #expect(sdk.inlineController.getCampaign("home_hero")?.campaignKey == "i2")
    }

    @Test("inline, same slot, displayed → surface_busy")
    func inlineSameSlotDisplayed() throws {
        try start([inlineJson("i1"), inlineJson("i2")])
        let first = deliver("i1", "cep-1")
        sdk.reportSlotFirstRender(first.payload)

        let second = deliver("i2", "cep-2")

        #expect(!first.isSettled)
        #expect(second.dropReason == .surfaceBusy)
        #expect(sdk.inlineController.getCampaign("home_hero")?.campaignKey == "i1")
    }

    // MARK: - Live test

    @Test("test over a test nudge → old dismissed and its row superseded, new shown")
    func liveTestOverLiveTest() throws {
        try start([])
        liveTest("inv-1", nudgeJson("t1"))
        try #require(sdk.controller.activeNudge?.payload.cepCampaignId == liveTestCepId("inv-1"))
        #expect(sdk.isLiveTestPendingForTesting("inv-1"))

        liveTest("inv-2", nudgeJson("t2"))

        #expect(sdk.controller.activeNudge?.payload.cepCampaignId == liveTestCepId("inv-2"))
        #expect(!sdk.isLiveTestPendingForTesting("inv-1"))
        #expect(sdk.isLiveTestPendingForTesting("inv-2"))
    }

    @Test("test over a real nudge → the real one settles superseded")
    func liveTestOverRealNudge() throws {
        try start([nudgeJson("real")])
        let real = deliver("real", "cep-1")

        liveTest("inv-1", nudgeJson("t1"))

        #expect(real.dropReason == .superseded)
        #expect(real.isHoldReleased)
        #expect(sdk.controller.activeNudge?.payload.cepCampaignId == liveTestCepId("inv-1"))
    }

    @Test("a test that fails screen targeting leaves the occupant on screen")
    func liveTestFailingTargetingKeepsOccupant() throws {
        try start([nudgeJson("real")])
        sdk.setCurrentScreen("Home")
        let real = deliver("real", "cep-1")

        liveTest("inv-1", nudgeJson("t1", targetScreenNames: ["Help"]))

        #expect(!real.isSettled)
        #expect(sdk.controller.activeNudge?.payload.campaignKey == "real")
    }

    @Test("a real campaign over a test → surface_busy (LT-Q2)")
    func realOverLiveTest() throws {
        try start([nudgeJson("real")])
        liveTest("inv-1", nudgeJson("t1"))

        let real = deliver("real", "cep-1")

        #expect(real.dropReason == .surfaceBusy)
        #expect(sdk.controller.activeNudge?.payload.cepCampaignId == liveTestCepId("inv-1"))
    }
}

// MARK: - Fixtures

private var emptyCanvas: [String: Any] {
    [
    "version": 2,
    "canvasWidth": 240,
    "canvasHeight": 120,
    "background": ["type": "solid", "color": ["value": "#FFFFFFFF"]],
    "children": [],
    ]
}

func nudgeJson(_ key: String, targetScreenNames: [String] = []) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "nudge",
        "targetScreenNames": ["names": targetScreenNames],
        "templateConfig": [
            "container": ["displayType": "dialog"],
            "layout": ["type": "digia/column", "props": [:], "children": []],
        ],
    ]
}

func floaterJson(_ key: String) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "floater",
        "templateConfig": [
            "templateType": "pip",
            "media": ["kind": "image", "url": "https://example.invalid/\(key).png"],
            "expanded": ["canvas": emptyCanvas],
        ] as [String: Any],
    ]
}

func guideJson(_ key: String) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "guide",
        "templateConfig": [
            "templateType": "tooltip",
            "steps": [
                [
                    "stepId": "step-1",
                    "anchorKey": "\(key)-anchor",
                    "layoutMode": "canvas",
                    "canvas": emptyCanvas,
                ] as [String: Any]
            ],
        ] as [String: Any],
    ]
}

func inlineJson(_ key: String, slotKey: String = "home_hero") -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "inline",
        "templateConfig": [
            "templateType": "canvas",
            "slotKey": slotKey,
            "designWidth": 360,
            "canvas": emptyCanvas,
        ] as [String: Any],
    ]
}
