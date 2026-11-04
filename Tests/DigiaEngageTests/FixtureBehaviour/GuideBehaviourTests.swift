import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// What the guide fixtures do before anyone touches them: how long a first step waits, and a guide
/// the SDK must never show. Each guide comes from the shared fixture, is delivered through the real
/// SDK and drawn by `DigiaHost` over `GuideAnchorsScreenSG`, which carries the anchors the fixtures
/// name. Placement, crops and outside taps are the sample app's `GuideBehaviourTests`.
///
/// Port of `flutter/core/test/fixture_behaviour/ui_guide_test.dart`.
@Suite("Guide: delays and refused guides", .serialized, .tags(.integration, .behaviour, .guide))
@MainActor
struct GuideBehaviourTests {

    /// Boots [path] over the anchors screen on `home` and delivers it.
    private func show(_ path: String) async throws -> SdkHarness {
        let sdk = try await SdkHarness.start(loadCampaign(path))
        try sdk.mount { GuideAnchorsScreenSG() }
        sdk.setCurrentScreen("home")
        try sdk.deliver(keyOf(try loadCampaign(path)))
        return sdk
    }

    // Fails if: guide_overlay_view.swift `isPresentationReady` stops waiting for
    // `delayElapsedForStep` (the step shows at once), or the delay task sleeps past `delayInMs`.
    @Test("waits the 1.5 s authored on its first step")
    func firstStepWaitsItsDelay() async throws {
        let path = "campaigns/degradation/degrade_guide_delay_then_missing_anchor.json"
        let sdk = try await SdkHarness.start(loadCampaign(path))
        defer { sdk.tearDown() }
        try sdk.mount { GuideAnchorsScreenSG() }
        let deliveredAt = Date()
        try sdk.deliver(keyOf(try loadCampaign(path)))

        // Still inside the delay: sampled until 1.3 s after the trigger.
        while Date().timeIntervalSince(deliveredAt) < 1.3 {
            #expect(!sdk.isShowing("Delayed first step"), "still inside the delay")
            try await sdk.settle(0.1)
        }
        try await sdk.waitUntil("past the delay", timeout: 2) { sdk.isShowing("Delayed first step") }
        #expect(Date().timeIntervalSince(deliveredAt) >= 1.4)
    }

    // Fails if: the guide parser accepts the removed `dismiss` outside-tap value.
    @Test("a guide carrying the removed `dismiss` outside-tap value is never shown")
    func removedOutsideTapValueNeverShows() async throws {
        let path = "campaigns/degradation/degrade_guide_removed_outside_tap_value.json"
        let sdk = try await show(path)
        defer { sdk.tearDown() }

        try await sdk.settle(2.1)

        #expect(!sdk.isShowing("Never shown"))
        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
    }
}
}
