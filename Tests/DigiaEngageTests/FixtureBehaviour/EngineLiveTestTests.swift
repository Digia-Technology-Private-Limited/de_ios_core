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
/// Fixture: `engine_surface_busy_second` (the campaign the PM is testing).
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

    private func boot() async throws -> (SdkHarness, tested: [String: Any]) {
        let tested = try fixture("engine/engine_surface_busy_second")
        let sdk = try await SdkHarness.start(campaigns: [tested])
        configureReporter(sdk)
        return (sdk, tested)
    }

    // Fails if `routeLiveTestCampaign` loses its `onWatchdogFired` teardown (`dismissSurfaces`): the
    // dashboard would hear `timeout` while the nudge stayed queued on the controller.
    // Kept: the YAML driver always mounts a host, so an accepted-but-never-appearing
    // live test is inexpressible in YAML.
    @Test("a live test accepted with no host to draw it answers timeout and leaves the surface", .tags(.slow))
    func acceptedWithNoHostTimesOut() async throws {
        let (sdk, tested) = try await boot()
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
}
}
