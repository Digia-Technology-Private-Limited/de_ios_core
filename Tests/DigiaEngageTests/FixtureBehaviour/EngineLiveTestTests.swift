import Foundation
import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A live test arriving at a running SDK: the step between the SSE stream (covered by
/// `NetworkLiveTest/`) and the dashboard row (pinned by `LiveTestReliabilityTests`). Every test drives
/// `SDKInstance.handleLiveTestCampaign`, the one entry the stream calls, and reads what reached the
/// backend: the ACKs and the tracked events.
///
/// Fixtures: `engine_surface_busy_first` (the organic nudge already up) and
/// `engine_surface_busy_second` (the campaign the PM is testing).
/// Port of `flutter/core/test/fixture_behaviour/engine_live_test_test.dart`.
@Suite("Engine: live test", .serialized, .tags(.integration, .behaviour, .nudge))
@MainActor
struct EngineLiveTestTests {

    private func invocation(_ campaign: [String: Any]?) -> LiveTestInvocation {
        LiveTestInvocation(
            testInvocationId: "inv-1",
            campaignId: "mock-engine-surface-busy-second",
            campaign: campaign,
            variables: [:]
        )
    }

    /// The ACK bodies posted for the invocation, in order.
    private func acks(_ sdk: SdkHarness) -> [[String: Any]] {
        sdk.network.recordedRequests
            .filter { $0.url.absoluteString == DigiaEndpoints.liveTestAck }
            .compactMap { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
    }

    private func statuses(_ sdk: SdkHarness) -> [String?] {
        acks(sdk).map { $0["status"] as? String }
    }

    private func failedCode(_ sdk: SdkHarness) -> String? {
        (acks(sdk).last?["reason"] as? [String: Any])?["code"] as? String
    }

    /// The reporter posts only once it has a config; `initialize` gives it one, and a test that never
    /// initializes gives it its own, as the Flutter suite configures its reporter.
    private func configureReporter(_ sdk: SdkHarness) {
        sdk.sdk.liveTestService.ackReporter.configure(config: DigiaConfig(apiKey: "test-api-key"))
    }

    private func boot() async throws -> (SdkHarness, organic: [String: Any], tested: [String: Any]) {
        let organic = try fixture("engine/engine_surface_busy_first")
        let tested = try fixture("engine/engine_surface_busy_second")
        let sdk = try await SdkHarness.start(campaigns: [organic, tested])
        configureReporter(sdk)
        return (sdk, organic, tested)
    }

    // Fails if `settleSuperseded`'s nudge case stops settling the occupant `superseded` for the CEP, or
    // stops sending Digia's own dismissal for a nudge that was displayed, in `SDKInstance.swift`.
    @Test("a live test takes the surface from the organic nudge: the CEP hears superseded, Digia reports the dismissal, and the test shows")
    func liveTestSupersedesTheOrganicNudge() async throws {
        let (sdk, organic, tested) = try await boot()
        defer { sdk.tearDown() }
        try sdk.mount { Text("host app") }
        let shown = try sdk.deliver(keyOf(organic))
        try await sdk.waitUntil("the organic nudge is up") { sdk.isShowing("First Nudge Holds The Surface") }

        sdk.sdk.handleLiveTestCampaign(invocation(tested))
        try await sdk.waitUntil("the tested nudge is up") { sdk.isShowing("Second Nudge Must Not Show") }

        #expect(!sdk.isShowing("First Nudge Holds The Surface"))
        #expect(shown.dismissReason == .superseded)
        try await sdk.waitUntil("the received and shown ACKs") { statuses(sdk).count >= 2 }
        #expect(statuses(sdk) == ["received", "shown"])

        // The tested nudge is still up, so the one dismissal is the organic one.
        let dismissals = try await sdk.events().filter { $0["event_name"] as? String == "Digia Experience Dismissed" }
        #expect(dismissals.count == 1)
        #expect((dismissals.first?["properties"] as? [String: Any])?["dismiss_reason"] as? String == "superseded")
    }

    // Fails if `routeLiveTestCampaign` loses its `onWatchdogFired` teardown (`dismissSurfaces`): the
    // dashboard would hear `timeout` while the nudge stayed queued on the controller.
    @Test("a live test accepted with no host to draw it answers timeout and leaves the surface", .tags(.slow))
    func acceptedWithNoHostTimesOut() async throws {
        let (sdk, _, tested) = try await boot()
        defer { sdk.tearDown() }

        sdk.sdk.handleLiveTestCampaign(invocation(tested))
        try await sdk.waitUntil("the tested nudge is queued") {
            sdk.sdk.controller.activeNudge?.payload.campaignKey == keyOf(tested)
        }

        try await sdk.waitUntil("the watchdog's failed ACK", timeout: LiveTestContext.watchdogTimeout + 3) {
            statuses(sdk) == ["received", "failed"]
        }
        #expect(failedCode(sdk) == "timeout")
        try await sdk.waitUntil("the nudge leaves the controller") { sdk.sdk.controller.activeNudge == nil }
    }

    // Fails if the `sdkState == .ready` guard is removed from `routeLiveTestCampaign`.
    @Test("a live test before the SDK is ready answers not_initialized")
    func beforeReadyAnswersNotInitialized() async throws {
        let tested = try fixture("engine/engine_surface_busy_second")
        let sdk = try SdkHarness.create(campaigns: [tested])
        defer { sdk.tearDown() }
        configureReporter(sdk)

        sdk.sdk.handleLiveTestCampaign(invocation(tested))

        try await sdk.waitUntil("the received and failed ACKs") { statuses(sdk).count >= 2 }
        #expect(statuses(sdk) == ["received", "failed"])
        #expect(failedCode(sdk) == "not_initialized")
    }

    // Fails if the `invocation.campaign == nil` branch of `routeLiveTestCampaign` reports any other code:
    // the dashboard's copy for a broken draft keys off it.
    @Test("a campaign the SDK cannot render answers malformed_campaign_skipped when the message carries no campaign object")
    func noCampaignObjectIsMalformed() async throws {
        let (sdk, _, _) = try await boot()
        defer { sdk.tearDown() }

        sdk.sdk.handleLiveTestCampaign(invocation(nil))

        try await sdk.waitUntil("the received and failed ACKs") { statuses(sdk).count >= 2 }
        #expect(statuses(sdk) == ["received", "failed"])
        #expect(failedCode(sdk) == "malformed_campaign_skipped")
    }

    // `fromJson` fails for a malformed config. Fails if the unparsed branch of `routeLiveTestCampaign`
    // reports any other code, or if the draft is routed anyway.
    @Test("a campaign the SDK cannot render answers malformed_campaign_skipped when the campaign object does not parse")
    func unparsableCampaignIsMalformed() async throws {
        let (sdk, _, tested) = try await boot()
        defer { sdk.tearDown() }

        var broken = tested
        broken["templateConfig"] = "not-an-object"
        sdk.sdk.handleLiveTestCampaign(invocation(broken))

        try await sdk.waitUntil("the received and failed ACKs") { statuses(sdk).count >= 2 }
        #expect(statuses(sdk) == ["received", "failed"])
        #expect(failedCode(sdk) == "malformed_campaign_skipped")
        #expect(sdk.sdk.controller.activeNudge == nil)
    }
}
}
