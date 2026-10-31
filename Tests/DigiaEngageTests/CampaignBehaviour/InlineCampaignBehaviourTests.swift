// tags: widget inline campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Inline content in its slot and the exact chain it sends. The CEP's hold comes back at acceptance, before
/// any impression, and the content sends no Digia Dismissed: when its slot is cleared, only the CEP hears of
/// it. The cases that need a real touch, and the carousel's (it pages only in a running app), run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/InlineCampaignBehaviourTests.swift`.
///
/// platform note: the Dart twin is `test/campaign_behaviour/inline_campaign_behaviour_test.dart`.
@MainActor
@Suite("Inline campaign behaviour", .serialized, .tags(.integration, .inline, .analytics))
struct InlineCampaignBehaviourTests {
    private func canvasCta() -> WorkspaceFixtures.Campaign {
        WorkspaceFixtures.campaign("campaigns/inline_canvas/inline_canvas_interactive_cta.json")
    }

    /// The app screen with `slotKey`'s slot at its top.
    private func start(_ campaigns: [WorkspaceFixtures.Campaign], slot slotKey: String) async throws -> SdkHarness {
        try await SdkHarness.startChain(campaigns) {
            VStack(spacing: 0) { DigiaSlot(slotKey); Spacer() }
        }
    }

    private func show(_ sdk: SdkHarness, _ d: Delivery) async throws {
        try await sdk.waitUntil("the inline impression", timeout: 5) { d.displayed }
        try await sdk.settle(0.5)
    }

    @Test("canvas: the host clears its slot: the CEP hears cancelled, Digia none")
    func hostClearsItsSlot() async throws {
        let key = "test_inline_canvas_cta"
        let sdk = try await start([canvasCta()], slot: "home_banner")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.clearInlineContent("home_banner")
        try await sdk.waitUntil("the slot is empty") { !sdk.isShowing("Special Wellness Program") }

        expectInlineChain(await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed], endedAs: .cancelled)
    }

    @Test("canvas: a second campaign for a shown slot: surface_busy")
    func secondCampaignForShownSlot() async throws {
        var json = canvasCta().json
        json["campaignKey"] = "test_inline_canvas_second"
        json["id"] = "mock-inline-canvas-second"
        let second = WorkspaceFixtures.Campaign(name: "inline_canvas_second", json: json)
        let sdk = try await start([canvasCta(), second], slot: "home_banner")
        defer { sdk.tearDown() }
        let incumbent = try sdk.deliverChain("test_inline_canvas_cta")
        try await show(sdk, incumbent)

        let blocked = try sdk.deliverChain("test_inline_canvas_second")
        try await sdk.settle(1)

        let events = await sdk.sent("test_inline_canvas_second")
        expectDropped(events, blocked, .surfaceBusy)
        #expect(propsOf(events, Chain.dropped)["blocking_campaign_key"] as? String == "test_inline_canvas_cta")
        expectInlineChain(await sdk.sent("test_inline_canvas_cta"), incumbent, names: [Chain.triggered, Chain.viewed])
    }

    // MARK: - Dropped

    /// Mounts or unmounts `home_banner` while a test runs, so a campaign can be delivered before its slot exists.
    @MainActor
    final class SlotSwitch: ObservableObject {
        @Published var mounted = false
    }

    private struct SwitchedSlot: View {
        @ObservedObject var slot: SlotSwitch
        var body: some View {
            VStack(spacing: 0) {
                if slot.mounted { DigiaSlot("home_banner") }
                Spacer()
            }
        }
    }

    private func secondCanvas() -> WorkspaceFixtures.Campaign {
        var json = canvasCta().json
        json["campaignKey"] = "test_inline_canvas_second"
        json["id"] = "mock-inline-canvas-second"
        return WorkspaceFixtures.Campaign(name: "inline_canvas_second", json: json)
    }

    // The slot has no view yet, so the first campaign has not displayed and the newer one takes its place.
    @Test("superseded: a newer inline campaign for a slot nothing has displayed in drops the older one before it shows")
    func supersededBeforeDisplay() async throws {
        let first = canvasCta()
        let second = secondCanvas()
        let slot = SlotSwitch()
        let sdk = try await SdkHarness.startChain([first, second]) { SwitchedSlot(slot: slot) }
        defer { sdk.tearDown() }
        let older = try sdk.deliverChain("test_inline_canvas_cta")
        try await sdk.settle(0.3)  // long enough to watch the CEP get its hold back at acceptance
        let newer = try sdk.deliverChain("test_inline_canvas_second")
        try await sdk.settle(0.5)
        slot.mounted = true
        try await show(sdk, newer)
        #expect(sdk.isShowing("Special Wellness Program"))

        expectDroppedWire(
            await sdk.sent("test_inline_canvas_cta"), older, .superseded, first, screen: nil,
            extras: [
                "superseded_by_campaign_key": "test_inline_canvas_second",
                "superseded_by_campaign_id": "mock-inline-canvas-second", "superseded_by_kind": "inline",
            ],
            detail: "ended before it displayed (superseded)", timeline: ["hold early", "outcome"])
        expectInlineChain(await sdk.sent("test_inline_canvas_second"), newer, names: [Chain.triggered, Chain.viewed])
    }

    // Registering another plugin is how a CEP integration is unregistered: the SDK settles what the old one owns.
    @Test("plugin_detached: replacing the CEP plugin drops its inline campaign that is still waiting for a slot")
    func pluginDetachedBeforeDisplay() async throws {
        let campaign = canvasCta()
        let slot = SlotSwitch()
        let sdk = try await SdkHarness.startChain([campaign]) { SwitchedSlot(slot: slot) }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain("test_inline_canvas_cta")
        try await sdk.settle(0.5)

        Digia.register(FakeCep())
        try await sdk.settle(0.5)

        expectDroppedWire(
            await sdk.sent("test_inline_canvas_cta"), d, .pluginDetached, campaign, screen: nil,
            timeline: ["hold early", "outcome"])
    }

    // As coded: inline campaigns are never frequency-capped (on every stack), so a cap of one does not stop the
    // same campaign showing again once its slot is cleared.
    @Test("inline: never frequency-capped, so a second delivery shows again despite a cap of one (as coded)")
    func neverCapped() async throws {
        let key = "test_inline_canvas_cta"
        let sdk = try await start([canvasCta().cappedAtOne()], slot: "home_banner")
        defer { sdk.tearDown() }
        let first = try sdk.deliverChain(key)
        try await show(sdk, first)
        Digia.clearInlineContent("home_banner")
        try await sdk.waitUntil("the slot is empty") { !sdk.isShowing("Special Wellness Program") }

        let second = try sdk.deliverChain(key)
        try await show(sdk, second)
        #expect(sdk.isShowing("Special Wellness Program"))

        let events = await sdk.sent(key)
        expectInlineChain(eventsOf(first, in: events), first, names: [Chain.triggered, Chain.viewed], endedAs: .cancelled)
        expectInlineChain(eventsOf(second, in: events), second, names: [Chain.triggered, Chain.viewed])
    }

    // CleverTap draws an inline by Native Display only; a `DigiaTemplate` in-app is the wrong channel for it.
    @Test("invalid_config: an inline campaign delivered as a CleverTap custom template is dropped as channel_mismatch")
    func channelMismatch() async throws {
        let key = "test_inline_canvas_cta"
        let campaign = canvasCta()
        let sdk = try await start([campaign], slot: "home_banner")
        defer { sdk.tearDown() }
        let host = try #require(sdk.cep.host)
        let d = Delivery(host.deliver(CEPTriggerPayload(
            cepCampaignId: "cep-\(key)", campaignKey: key, cepMetadata: ["templateName": "DigiaTemplate"])))
        try await sdk.settle(1)
        #expect(!sdk.isShowing("Special Wellness Program"))

        expectDroppedWire(
            await sdk.sent(key), d, .invalidConfig, campaign, screen: nil, extras: ["cause": "channel_mismatch"],
            detail: "inline campaign delivered as a CleverTap custom template")
    }

    @Test("inline: a CEP cancel before it shows drops it as cancelled")
    func cepCancelBeforeShowing() async throws {
        let key = "test_inline_canvas_cta"
        let campaign = canvasCta()
        let slot = SlotSwitch()
        let sdk = try await SdkHarness.startChain([campaign]) { SwitchedSlot(slot: slot) }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await sdk.settle(0.3)
        d.presentation.cancel()
        try await sdk.settle(0.5)
        slot.mounted = true
        try await sdk.settle(1)
        #expect(!sdk.isShowing("Special Wellness Program"), "nothing is drawn once the slot appears")

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil, extras: ["cancel_cause": "cep_cancel"],
            detail: "ended before it displayed (cancelled)", timeline: ["hold early", "outcome"])
    }

    @Test("inline: delivered off its target screen drops as screen_not_targeted")
    func offItsTargetScreen() async throws {
        let key = "test_inline_canvas_cta"
        let campaign = canvasCta().targeting(["home"])
        let sdk = try await start([campaign], slot: "home_banner")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1)
        #expect(!sdk.isShowing("Special Wellness Program"))

        expectDroppedWire(
            await sdk.sent(key), d, .screenNotTargeted, campaign, screen: "search",
            extras: ["target_screens": ["home"]], detail: "currentScreen=search targetScreenNames=[\"home\"]")
    }
}
}
