import Foundation
import Testing
@testable import DigiaEngage

/// Covers `SDKInstance.handleLiveTestCampaign` — the live-test entry point —
/// and the two lessons carried over from the Flutter port's audit: the
/// transient campaign cache must be keyed by `cepCampaignId` (not
/// `campaignKey`, so a re-test of an edited campaign never collides with a
/// still-in-flight sibling test), and it must never leak an entry past a
/// terminal ACK.
@MainActor
@Suite("LiveTestRouting", .serialized)
struct LiveTestRoutingTests {
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func setUp() -> FakeAckSender {
        SDKInstance.shared.resetForTesting()
        SDKInstance.shared.markInitializedForTesting(with: DigiaConfig(apiKey: "digia_test"))
        // markInitializedForTesting only seeds `config`; handleLiveTestCampaign
        // additionally requires `sdkState == .ready`, which only
        // setCampaignsForTesting sets.
        SDKInstance.shared.setCampaignsForTesting([])
        let sender = FakeAckSender()
        let reporter = LiveTestAckReporter(sender: sender)
        reporter.configure(config: DigiaConfig(apiKey: "digia_test"), deviceId: "device-1")
        SDKInstance.shared.setLiveTestServiceForTesting(LiveTestService(ackReporter: reporter))
        return sender
    }

    /// `received` and the terminal status (`shown`/`failed`) are posted via two
    /// independent fire-and-forget Tasks with no ordering guarantee between
    /// them (matching the backend's own "late ACK" semantics) — so this
    /// returns a `Set`, not an ordered array, and callers must not assert on
    /// arrival order.
    private func statuses(_ sender: FakeAckSender, _ testInvocationId: String) -> Set<String> {
        Set(
            sender.bodies
                .filter { ($0["testInvocationId"] as? String) == testInvocationId }
                .compactMap { $0["status"] as? String }
        )
    }

    private func failureCode(_ sender: FakeAckSender, _ testInvocationId: String) -> String? {
        sender.bodies.last {
            ($0["testInvocationId"] as? String) == testInvocationId && ($0["status"] as? String) == "failed"
        }.flatMap { ($0["reason"] as? [String: Any])?["code"] as? String }
    }

    private var nudgeCampaignJson: [String: Any] {
        [
            "id": "c1",
            "campaignKey": "welcome_nudge",
            "campaignType": "nudge",
            "templateConfig": ["layout": ["type": "column", "props": [String: Any]()]],
        ]
    }

    private var surveyCampaignJson: [String: Any] {
        [
            "id": "c2",
            "campaignKey": "nps_survey",
            "campaignType": "survey",
            "templateConfig": [
                "templateType": "survey",
                "blocks": [
                    [
                        "id": "block-1",
                        "type": "single_select",
                        "title": ["text": "How are you?"],
                        "options": [
                            ["id": "opt_a", "label": "Good"],
                            ["id": "opt_b", "label": "Bad"],
                        ],
                    ]
                ],
                "nodes": [["id": "node-1", "blockId": "block-1"]],
            ],
        ]
    }

    @Test("nudge live test acks received then shown, and never reaches a real CEP plugin")
    func nudgeLiveTestAcksShown() async throws {
        let sender = setUp()
        let plugin = TestCepPlugin()
        Digia.register(plugin)

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_1", campaignId: "c1", campaign: nudgeCampaignJson, variables: [:])
        )
        SDKInstance.shared.reportNudgeImpression()
        try await settle()

        #expect(statuses(sender, "test_1") == Set(["received", "shown"]))
        #expect(plugin.events.isEmpty, "live test must never reach a real CEP plugin")
    }

    @Test("survey live test acks received then shown, and never reaches a real CEP plugin")
    func surveyLiveTestAcksShown() async throws {
        let sender = setUp()
        let plugin = TestCepPlugin()
        Digia.register(plugin)

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_2", campaignId: "c2", campaign: surveyCampaignJson, variables: [:])
        )
        SDKInstance.shared.reportSurveyStarted()
        try await settle()

        #expect(statuses(sender, "test_2") == Set(["received", "shown"]))
        #expect(plugin.events.isEmpty)
    }

    @Test("a survey test while another survey is already showing acks failed render_error")
    func secondSurveyTestFailsWhileFirstOpen() async throws {
        let sender = setUp()

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_3", campaignId: "c2", campaign: surveyCampaignJson, variables: [:])
        )
        // A second survey test arrives before the first is dismissed.
        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_4", campaignId: "c2", campaign: surveyCampaignJson, variables: [:])
        )
        try await settle()

        #expect(statuses(sender, "test_3") == Set(["received"]))
        #expect(statuses(sender, "test_4") == Set(["received", "failed"]))
        #expect(failureCode(sender, "test_4") == "render_error")
    }

    @Test("guide and inline campaign types are rejected before ever routing")
    func guideAndInlineAreRejected() async throws {
        let sender = setUp()

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(
                testInvocationId: "test_5", campaignId: "g1",
                campaign: ["id": "g1", "campaignKey": "g_key", "campaignType": "guide"], variables: [:]
            )
        )
        try await settle()

        #expect(statuses(sender, "test_5") == Set(["received", "failed"]))
        #expect(failureCode(sender, "test_5") == "template_error")
        #expect(!SDKInstance.shared.liveTestCampaignsForTesting().values.contains { $0.campaignKey == "g_key" })
    }

    @Test("a malformed campaign object acks template_error")
    func malformedCampaignActsTemplateError() async throws {
        let sender = setUp()

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_6", campaignId: "c9", campaign: ["id": "c9"], variables: [:])
        )
        try await settle()

        #expect(statuses(sender, "test_6") == Set(["received", "failed"]))
        #expect(failureCode(sender, "test_6") == "template_error")
    }

    @Test("a missing campaign object acks campaign_not_found")
    func missingCampaignActsCampaignNotFound() async throws {
        let sender = setUp()

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_7", campaignId: "c9", campaign: nil, variables: [:])
        )
        try await settle()

        #expect(statuses(sender, "test_7") == Set(["received", "failed"]))
        #expect(failureCode(sender, "test_7") == "campaign_not_found")
    }

    @Test("re-testing the same campaign key never collides with a still-open sibling test")
    func retestingSameKeyDoesNotCollide() async throws {
        _ = setUp()

        // Same campaignKey ("welcome_nudge"), two distinct invocations — the
        // exact "edit and re-test" scenario the audit lesson is about: keying
        // by cepCampaignId (not campaignKey) means neither entry can clobber
        // the other while both are in flight.
        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_9", campaignId: "c1", campaign: nudgeCampaignJson, variables: [:])
        )
        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_10", campaignId: "c1", campaign: nudgeCampaignJson, variables: [:])
        )
        try await settle()

        #expect(SDKInstance.shared.liveTestCampaignsForTesting().count == 2)
        #expect(SDKInstance.shared.liveTestContextsForTesting().count == 2)
    }

    @Test("a terminal ACK removes the transient cache entries so nothing leaks")
    func terminalAckClearsTransientState() async throws {
        _ = setUp()

        SDKInstance.shared.handleLiveTestCampaignForTesting(
            LiveTestInvocation(testInvocationId: "test_11", campaignId: "c1", campaign: nudgeCampaignJson, variables: [:])
        )
        #expect(SDKInstance.shared.liveTestCampaignsForTesting().count == 1)
        #expect(SDKInstance.shared.liveTestContextsForTesting().count == 1)

        SDKInstance.shared.reportNudgeImpression() // fires the "shown" terminal ACK
        try await settle()

        #expect(SDKInstance.shared.liveTestCampaignsForTesting().isEmpty)
        #expect(SDKInstance.shared.liveTestContextsForTesting().isEmpty)
    }
}

private final class TestCepPlugin: DigiaCEPPlugin {
    let identifier = "fake"
    var events: [(DigiaExperienceEvent, CEPTriggerPayload)] = []

    func setup(delegate: DigiaCEPDelegate) {}
    func forwardScreen(_ name: String) {}
    func registerPlaceholder(propertyID: String) -> Int? { nil }
    func deregisterPlaceholder(_ id: Int) {}

    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        events.append((event, payload))
    }

    func healthCheck() -> DiagnosticReport { DiagnosticReport(isHealthy: true) }
    func teardown() {}
}
