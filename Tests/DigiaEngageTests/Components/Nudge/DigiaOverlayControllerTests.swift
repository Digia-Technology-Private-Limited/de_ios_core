import Foundation
import Testing
@testable import DigiaEngage

@Suite("Digia overlay controller", .serialized, .tags(.nudge, .unit))
struct DigiaOverlayControllerTests {

    private func makeNudgePresentation(
        id: String,
        autoDismissAfterMs: Int = 0
    ) -> DigiaNudgePresentation {
        guard let fixture = FixtureLoader.loadFixture(campaignType: "nudge_dialog", fileName: "nudge-dialog"),
              var templateConfig = fixture["templateConfig"] as? [String: Any] else {
            fatalError("Failed to load nudge-dialog fixture")
        }
        var container = templateConfig["container"] as? [String: Any] ?? [:]
        container["autoDismissAfterMs"] = autoDismissAfterMs
        templateConfig["container"] = container
        guard let config = NudgeConfig.fromJson(templateConfig) else {
            fatalError("Failed to parse nudge config")
        }
        return DigiaNudgePresentation(
            config: config,
            payload: CEPTriggerPayload(cepCampaignId: id, campaignKey: "campaign_1", cepMetadata: [:]),
            variables: nil
        )
    }

    @Test("showNudge and dismissNudge update activeNudge state") @MainActor
    func testShowAndDismissNudge() {
        let controller = DigiaOverlayController()
        let presentation = makeNudgePresentation(id: "ctrl_test_1")

        controller.showNudge(presentation)
        #expect(controller.activeNudge?.id == "ctrl_test_1")

        controller.dismissNudge()
        #expect(controller.activeNudge == nil)
    }

    @Test("forceNudgeDismiss clears activeNudge instantly") @MainActor
    func testForceNudgeDismiss() {
        let controller = DigiaOverlayController()
        let presentation = makeNudgePresentation(id: "ctrl_test_2")

        controller.showNudge(presentation)
        #expect(controller.activeNudge?.id == "ctrl_test_2")

        controller.forceNudgeDismiss()
        #expect(controller.activeNudge == nil)
    }

    @Test("startNudgeAutoDismiss fires after configured delay") @MainActor
    func testAutoDismissFires() async throws {
        let controller = SDKInstance.shared.controller
        let presentation = makeNudgePresentation(id: "ctrl_test_auto", autoDismissAfterMs: 30)

        controller.showNudge(presentation)
        #expect(controller.activeNudge?.id == "ctrl_test_auto")

        controller.startNudgeAutoDismiss()
        #expect(controller.activeNudge?.id == "ctrl_test_auto")

        // Wait for 30ms auto-dismiss task to fire and dismiss (poll up to 1s)
        for _ in 0..<50 {
            if controller.activeNudge == nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(controller.activeNudge == nil)
    }

    @Test("startNudgeAutoDismiss does not fire when autoDismissAfterMs is zero or negative") @MainActor
    func testAutoDismissZeroIgnored() async throws {
        let controller = DigiaOverlayController()
        let presentation = makeNudgePresentation(id: "ctrl_test_zero", autoDismissAfterMs: 0)

        controller.showNudge(presentation)
        #expect(controller.activeNudge?.id == "ctrl_test_zero")

        controller.startNudgeAutoDismiss()
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(controller.activeNudge?.id == "ctrl_test_zero")

        controller.forceNudgeDismiss()
    }

    @Test("showStoryOverlay and dismissStoryOverlay manage active story state") @MainActor
    func testStoryOverlayState() {
        let controller = DigiaOverlayController()
        let config = InlineStoryConfig(slotKey: "test_slot", items: [])
        let payload = CEPTriggerPayload(cepCampaignId: "story_campaign", campaignKey: "campaign_1", cepMetadata: [:])

        controller.showStoryOverlay(config: config, initialIndex: 0, payload: payload)
        #expect(controller.activeStoryOverlay != nil)
        #expect(controller.activeStoryOverlay?.config.slotKey == "test_slot")
        #expect(controller.activeStoryOverlay?.payload.cepCampaignId == "story_campaign")

        controller.dismissStoryOverlay()
        #expect(controller.activeStoryOverlay == nil)
    }
}
