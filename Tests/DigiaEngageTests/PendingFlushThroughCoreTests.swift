import Foundation
import Testing

@testable import DigiaEngage

/// What a user gets when campaigns reach a plugin before core is READY: the plugin's
/// `PendingPayloadBuffer` is flushed from `onHostReady()` into a real `SDKInstance`, so
/// the outcome is decided by the buffer's flush order, the READY notification and core's
/// own routing together. `PendingPayloadBufferTests` pins the buffer alone; these pin
/// what lands on screen.
@MainActor
@Suite("Pending buffer flushed into core on READY", .serialized)
struct PendingFlushThroughCoreTests {

    private let network = HeldBundleNetworkClient()
    private let sdk: SDKInstance
    private let plugin = FlushingPlugin()

    init() async throws {
        sdk = SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { [network] _ in network }
        )
        sdk.register(plugin)
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        #expect(sdk.sdkState == .initializing)
        #expect(plugin.host?.isReady == false)
    }

    private func becomeReady(with campaigns: [[String: Any]]) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["campaigns": campaigns])
        network.release(
            .success(NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)))
        for _ in 0..<200 where sdk.sdkState != .ready {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try #require(sdk.sdkState == .ready)
    }

    @Test("20 inlines held before READY are all delivered on READY, one per slot")
    func inlinesAllDelivered() async throws {
        let campaigns = (1...20).map { inlineJson("i\($0)", slotKey: "slot\($0)") }
        for index in 1...20 { plugin.receive("i\(index)") }
        #expect(plugin.buffer.length == 20)

        try await becomeReady(with: campaigns)

        #expect(plugin.buffer.length == 0)
        #expect(plugin.delivered.count == 20)
        #expect(plugin.delivered.allSatisfy { !$0.isSettled })
        for index in 1...20 {
            #expect(sdk.inlineController.getCampaign("slot\(index)")?.campaignKey == "i\(index)")
        }
    }

    @Test("in-apps that share the surface: the newest held one displays, the older ones are dropped")
    func newestBlockingInAppWins() async throws {
        let campaigns = [nudgeJson("nudge"), surveyJson("survey"), guideJson("guide")]
        // Arrival order: nudge, survey, guide. The guide arrived last.
        for key in ["nudge", "survey", "guide"] { plugin.receive(key) }

        try await becomeReady(with: campaigns)

        let byKey = Dictionary(uniqueKeysWithValues: plugin.delivered.map { ($0.payload.campaignKey, $0) })
        #expect(byKey["guide"]?.isSettled == false)
        #expect(sdk.guideOrchestrator.state?.payload.campaignKey == "guide")
        #expect(byKey["survey"]?.dropReason != nil)
        #expect(byKey["nudge"]?.dropReason != nil)
        #expect(sdk.controller.activeNudge == nil)
    }

    @Test("inlines and in-apps held together: every inline stays, only the newest in-app displays")
    func mixedInlineAndInApp() async throws {
        let campaigns = [
            inlineJson("i1", slotKey: "slot1"), nudgeJson("nudge1"),
            inlineJson("i2", slotKey: "slot2"), nudgeJson("nudge2"),
        ]
        for key in ["i1", "nudge1", "i2", "nudge2"] { plugin.receive(key) }

        try await becomeReady(with: campaigns)

        #expect(sdk.inlineController.getCampaign("slot1")?.campaignKey == "i1")
        #expect(sdk.inlineController.getCampaign("slot2")?.campaignKey == "i2")
        #expect(sdk.controller.activeNudge?.payload.campaignKey == "nudge2")
        let older = try #require(plugin.delivered.first { $0.payload.campaignKey == "nudge1" })
        #expect(older.dropReason != nil)
    }

    @Test("a payload arriving after READY goes straight to core and is never held")
    func afterReadyGoesStraightThrough() async throws {
        try await becomeReady(with: [inlineJson("late", slotKey: "slot_late")])

        plugin.receive("late")

        #expect(plugin.buffer.length == 0)
        #expect(plugin.delivered.count == 1)
        #expect(sdk.inlineController.getCampaign("slot_late")?.campaignKey == "late")
    }
}

/// A plugin that buffers the way the CEP plugins do: hold while the host is not READY,
/// flush from `onHostReady()`.
@MainActor
private final class FlushingPlugin: DigiaCEPPlugin {
    let id = "flushing"
    var host: DigiaCEPHost?
    var delivered: [PresentationRecorder] = []
    private(set) var buffer: PendingPayloadBuffer!

    init() {
        buffer = PendingPayloadBuffer(onDrop: { _, _ in })
    }

    func attach(host: DigiaCEPHost) { self.host = host }

    func detach() { buffer.dropAll(DropReason.pluginDetached) }

    func onHostReady() {
        buffer.takeAll().forEach(deliver)
    }

    func receive(_ campaignKey: String) {
        let trigger = CEPTriggerPayload(cepCampaignId: "cep-\(campaignKey)", campaignKey: campaignKey, cepMetadata: [:])
        guard let host, host.isReady else { return buffer.add(trigger) }
        deliver(trigger)
    }

    private func deliver(_ trigger: CEPTriggerPayload) {
        guard let host else { return }
        delivered.append(PresentationRecorder(host.deliver(trigger)))
    }
}
