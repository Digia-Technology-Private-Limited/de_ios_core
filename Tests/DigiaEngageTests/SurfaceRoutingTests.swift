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

    @Test("a surface_busy drop's timeline record names the blocker (SR10)")
    func busyRecordCarriesBlocker() async throws {
        let sink = TimelineRecorder()
        DigiaLogger.registerSink(sink)
        defer { DigiaLogger.unregisterSink(sink) }
        try start([nudgeJson("welcome"), nudgeJson("sale")])
        _ = deliver("welcome", "cep-1")
        // A never-displayed blocker is not named (SR64).
        sdk.reportNudgeImpression()
        _ = deliver("sale", "cep-2")

        var record: TimelineRecord?
        for _ in 0..<50 where record == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
            record = sink.records.first { $0.reason?.wire == "surface_busy" && $0.campaignKey == "sale" }
        }
        let busy = try #require(record)
        #expect(busy.extras["blocking_campaign_key"] == "welcome")
        #expect(busy.extras["blocking_kind"] == "nudge")
        #expect(busy.extras[HealthReasons.liveTestBlockerKey] == nil)
    }

    @Test("RN classic guide over a nudge → surface_busy, not sent to JS (SR21)")
    func classicGuideOverNudge() throws {
        try start([nudgeJson("n"), classicGuideJson("classic")])
        sdk.markInitializedForTesting(with: DigiaConfig(apiKey: "k", wrapperBinding: "react_native"))
        var rendered: [String] = []
        sdk.onGuideRenderRequest = { rendered.append($0.payload.campaignKey) }
        defer { sdk.onGuideRenderRequest = nil }

        _ = deliver("n", "cep-1")
        let guide = deliver("classic", "cep-2")

        #expect(guide.dropReason == .surfaceBusy)
        #expect(rendered.isEmpty)
    }

    @Test("RN classic guide on a free screen is still sent to JS (SR21)")
    func classicGuideAlone() throws {
        try start([classicGuideJson("classic")])
        sdk.markInitializedForTesting(with: DigiaConfig(apiKey: "k", wrapperBinding: "react_native"))
        var rendered: [String] = []
        sdk.onGuideRenderRequest = { rendered.append($0.payload.campaignKey) }
        defer { sdk.onGuideRenderRequest = nil }

        let guide = deliver("classic", "cep-1")

        #expect(!guide.isSettled)
        #expect(rendered == ["classic"])
    }

    @Test("nudge over an RN classic guide → surface_busy until the guide settles")
    func nudgeOverClassicGuide() throws {
        try start([classicGuideJson("classic"), nudgeJson("n")])
        sdk.markInitializedForTesting(with: DigiaConfig(apiKey: "k", wrapperBinding: "react_native"))
        var presentationId = ""
        sdk.onGuideRenderRequest = { presentationId = $0.presentationId }
        defer { sdk.onGuideRenderRequest = nil }

        _ = deliver("classic", "cep-1")
        sdk.reportExternalGuideLifecycle(presentationId: presentationId, event: .displaying)
        let blocked = deliver("n", "cep-2")
        sdk.reportExternalGuideLifecycle(
            presentationId: presentationId, event: .settled(.dismissed(reason: .userClose, completed: false)))
        let shown = deliver("n", "cep-3")

        #expect(blocked.dropReason == .surfaceBusy)
        #expect(!shown.isSettled)
        #expect(sdk.controller.activeNudge?.payload.cepCampaignId == "cep-3")
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

func classicGuideJson(_ key: String) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "guide",
        "templateConfig": [
            "templateType": "tooltip",
            "steps": [
                ["stepId": "step-1", "anchorKey": "\(key)-anchor", "title": "Hi"] as [String: Any]
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

private final class TimelineRecorder: DiagnosticSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimelineRecord] = []

    var records: [TimelineRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func accepts(_ record: TimelineRecord) -> Bool { true }

    func emit(_ record: TimelineRecord) {
        lock.lock()
        stored.append(record)
        lock.unlock()
    }
}
