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

    private var core: SDKInstance { SDKInstance.shared }

    private func presentation(_ sdk: SdkHarness, _ key: String) throws -> CampaignPresentation {
        try #require(sdk.cep.presentations.first { $0.campaignKey == key }?.presentation)
    }

    private func dropReason(_ outcome: PresentationOutcome?) -> DropReason? {
        if case .dropped(let reason, _) = outcome { return reason }
        return nil
    }

    @Test("20 inlines held before READY are all delivered on READY, one per slot")
    func inlinesAllDelivered() async throws {
        func inline(_ n: Int) -> [String: Any] { inlineJson("i\(n)", slotKey: "slot\(n)") }
        let sdk = try await SdkHarness.startHeld(
            inline(1), inline(2), inline(3), inline(4), inline(5), inline(6), inline(7),
            inline(8), inline(9), inline(10), inline(11), inline(12), inline(13), inline(14),
            inline(15), inline(16), inline(17), inline(18), inline(19), inline(20))
        defer { sdk.tearDown() }
        #expect(sdk.cep.host?.isReady == false)
        for index in 1...20 { sdk.cep.receive("i\(index)") }
        #expect(sdk.cep.buffered == 20)

        try await sdk.releaseBundle()

        #expect(sdk.cep.buffered == 0)
        #expect(sdk.cep.presentations.count == 20)
        #expect(sdk.cep.presentations.allSatisfy { sdk.outcome(of: $0.presentation) == nil })
        for index in 1...20 {
            #expect(core.inlineController.getCampaign("slot\(index)")?.campaignKey == "i\(index)")
        }
    }

    @Test("in-apps that share the surface: the newest held one displays, the older ones are dropped")
    func newestBlockingInAppWins() async throws {
        let sdk = try await SdkHarness.startHeld(nudgeJson("nudge"), surveyJson("survey"), guideJson("guide"))
        defer { sdk.tearDown() }
        #expect(sdk.cep.host?.isReady == false)
        // Arrival order: nudge, survey, guide. The guide arrived last.
        for key in ["nudge", "survey", "guide"] { sdk.cep.receive(key) }

        try await sdk.releaseBundle()

        #expect(sdk.outcome(of: try presentation(sdk, "guide")) == nil)
        #expect(core.guideOrchestrator.state?.payload.campaignKey == "guide")
        #expect(dropReason(sdk.outcome(of: try presentation(sdk, "survey"))) != nil)
        #expect(dropReason(sdk.outcome(of: try presentation(sdk, "nudge"))) != nil)
        #expect(core.controller.activeNudge == nil)
    }

    @Test("inlines and in-apps held together: every inline stays, only the newest in-app displays")
    func mixedInlineAndInApp() async throws {
        let sdk = try await SdkHarness.startHeld(
            inlineJson("i1", slotKey: "slot1"), nudgeJson("nudge1"),
            inlineJson("i2", slotKey: "slot2"), nudgeJson("nudge2"))
        defer { sdk.tearDown() }
        #expect(sdk.cep.host?.isReady == false)
        for key in ["i1", "nudge1", "i2", "nudge2"] { sdk.cep.receive(key) }

        try await sdk.releaseBundle()

        #expect(core.inlineController.getCampaign("slot1")?.campaignKey == "i1")
        #expect(core.inlineController.getCampaign("slot2")?.campaignKey == "i2")
        #expect(core.controller.activeNudge?.payload.campaignKey == "nudge2")
        #expect(dropReason(sdk.outcome(of: try presentation(sdk, "nudge1"))) != nil)
    }

    @Test("a payload arriving after READY goes straight to core and is never held")
    func afterReadyGoesStraightThrough() async throws {
        let sdk = try await SdkHarness.startHeld(inlineJson("late", slotKey: "slot_late"))
        defer { sdk.tearDown() }
        #expect(sdk.cep.host?.isReady == false)
        try await sdk.releaseBundle()

        #expect(sdk.cep.receive("late") != nil)

        #expect(sdk.cep.buffered == 0)
        #expect(sdk.cep.presentations.count == 1)
        #expect(core.inlineController.getCampaign("slot_late")?.campaignKey == "late")
    }
}
