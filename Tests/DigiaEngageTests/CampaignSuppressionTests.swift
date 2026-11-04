import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: these reset SDKInstance.shared.
extension DigiaEngageTests {
    /// The `setCampaignsSuppressed` contract (`campaign-suppression`, issue #154):
    /// while the host suppresses overlays, an overlay delivery drops as
    /// `host_suppressed` with its CEP hold released, inline keeps rendering,
    /// and unsuppressing restores overlays.
    ///
    /// Every delivery goes through `SdkHarness` — the real `initialize`, the
    /// real host `deliver` path with a real hold — so what each test asserts
    /// is what a customer's CEP plugin would see. `tearDown` resets the
    /// suppression flag with everything else, so tests never leak it.
    @MainActor
    @Suite("Campaign suppression", .serialized, .tags(.integration, .surface, .cep))
    struct CampaignSuppressionTests {
        // dmc-case: dmc.gate_order.suppressed_overlay_drops_host_suppressed
        // dmc-case: dmc.gate_order.suppression_checked_before_screen_and_frequency
        @Test("while suppressed, an overlay delivery drops host_suppressed and releases the hold")
        func suppressedOverlayDropsAndReleases() async throws {
            let sdk = try await SdkHarness.start(campaigns: [nudgeJson("n")])
            defer { sdk.tearDown() }
            Digia.setCampaignsSuppressed(true)

            let dropped = PresentationRecorder(try sdk.deliver("n"))

            #expect(dropped.isSettled)
            #expect(dropped.dropReason == .hostSuppressed)
            // The critical invariant: the drop settles together with the hold,
            // or the CEP's queue jams behind a slot nobody owns.
            #expect(dropped.isHoldReleased)
            #expect(sdk.sdk.controller.activeNudge == nil)

            // The organic path routes through the same gate.
            let hosted = PresentationRecorder(sdk.sdk.triggerCampaign("n", variables: nil))
            #expect(hosted.dropReason == .hostSuppressed)
            #expect(hosted.isHoldReleased)
        }

        // dmc-case: dmc.gate_order.suppressed_inline_still_routes
        @Test("while suppressed, an inline delivery still gets through")
        func suppressedInlineStillRenders() async throws {
            let sdk = try await SdkHarness.start(campaigns: [inlineJson("i", slotKey: "home_hero")])
            defer { sdk.tearDown() }
            Digia.setCampaignsSuppressed(true)

            let inline = PresentationRecorder(try sdk.deliver("i"))

            // Accepted, so still pending: a drop would have settled at once.
            #expect(!inline.isSettled)
            #expect(inline.isHoldReleased)
        }

        // dmc-case: dmc.gate_order.unsuppress_restores_overlay
        @Test("after unsuppressing, an overlay delivery is accepted again")
        func unsuppressRestoresOverlays() async throws {
            let sdk = try await SdkHarness.start(campaigns: [nudgeJson("n")])
            defer { sdk.tearDown() }
            Digia.setCampaignsSuppressed(true)

            let dropped = PresentationRecorder(try sdk.deliver("n"))
            #expect(dropped.dropReason == .hostSuppressed)

            Digia.setCampaignsSuppressed(false)
            let restored = PresentationRecorder(try sdk.deliver("n"))

            #expect(!restored.isSettled)
            #expect(sdk.sdk.controller.activeNudge?.payload.campaignKey == "n")
        }

        // dmc-case: dmc.gate_order.template_config_gate_drops_invalid_config
        @Test("a channel mismatch while suppressed is still invalid_config")
        func channelMismatchBeatsSuppression() async throws {
            let sdk = try await SdkHarness.start(campaigns: [floaterJson("pip")])
            defer { sdk.tearDown() }
            Digia.setCampaignsSuppressed(true)

            // A floater delivered as a CleverTap custom template is a router-level
            // channel mismatch, checked before the suppression gate.
            let dropped = PresentationRecorder(
                try sdk.deliver("pip", metadata: ["templateName": "DigiaTemplate"]))

            #expect(dropped.dropReason == .invalidConfig)
            #expect(dropped.isHoldReleased)
        }

        // dmc-case: dmc.freq.suppressed_trigger_skips_cap
        // dmc-case: dmc.gate_order.suppression_checked_before_screen_and_frequency
        @Test("a suppressed trigger never consumes a frequency cap")
        func suppressedTriggerSkipsFrequencyCap() async throws {
            var once = nudgeJson("once")
            once["frequency"] = ["maxTotal": 1]
            let sdk = try await SdkHarness.start(campaigns: [once])
            defer { sdk.tearDown() }

            Digia.setCampaignsSuppressed(true)
            #expect(PresentationRecorder(try sdk.deliver("once")).dropReason == .hostSuppressed)
            Digia.setCampaignsSuppressed(false)

            // The suppressed drop above must not have spent the single impression.
            let shown = PresentationRecorder(try sdk.deliver("once"))
            #expect(!shown.isSettled)
            sdk.sdk.reportNudgeImpression()
            sdk.sdk.markNudgeDismissed()

            // ...which this cap proves is working: the real impression spent it.
            #expect(PresentationRecorder(try sdk.deliver("once")).dropReason == .frequencyCapped)
        }

        // dmc-case: dmc.gate_order.unsuppress_restores_overlay
        @Test("suppression set before initialize() is honoured once ready")
        func suppressionBeforeInitializeIsHonoured() async throws {
            let sdk = try await SdkHarness.startHeld(nudgeJson("n"))
            // Set while the SDK is still initializing: the flag lives outside
            // the services graph, so it is honoured once the SDK is ready.
            Digia.setCampaignsSuppressed(true)
            try await sdk.releaseBundle()
            defer { sdk.tearDown() }

            let dropped = PresentationRecorder(try sdk.deliver("n"))

            #expect(dropped.dropReason == .hostSuppressed)
            #expect(dropped.isHoldReleased)
        }
    }
}
