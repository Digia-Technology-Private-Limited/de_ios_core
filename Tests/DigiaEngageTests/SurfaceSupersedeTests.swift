import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: guides here drive AnchorRegistry.shared.
extension DigiaEngageTests {
    /// Round 2 of the surface rule (plan §7): supersede analytics (SR44, D5),
    /// same-campaign redelivery (SR43, D4), and a live test that fails a
    /// precondition leaving the occupant alone (SR48).
    @MainActor
    @Suite("Surface rule round 2", .serialized)
    struct SurfaceSupersedeTests {
        private func makeSdk(_ campaigns: [[String: Any]]) async throws -> SDKInstance {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            sdk.setCampaignsForTesting(try campaigns.map { try #require(CampaignModel.fromJson($0)) })
            return sdk
        }

        private func deliver(_ sdk: SDKInstance, _ key: String, _ cepId: String) -> PresentationRecorder {
            PresentationRecorder(
                sdk.deliver(CEPTriggerPayload(cepCampaignId: cepId, campaignKey: key, cepMetadata: [:])))
        }

        private func liveTest(_ sdk: SDKInstance, _ invocationId: String, _ campaign: [String: Any]) {
            sdk.handleLiveTestCampaign(
                LiveTestInvocation(
                    testInvocationId: invocationId, campaignId: "id", campaign: campaign, variables: [:]))
        }

        private func digiaEvents(_ sdk: SDKInstance) async throws -> [(name: String, props: [String: Any])] {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let analytics = try #require(sdk.services?.analyticsService)
            return analytics.queue.peek(maxCount: 100).compactMap { entry in
                guard let name = entry.payload["event_name"] as? String, name.hasPrefix("Digia ") else {
                    return nil
                }
                return (name, entry.payload["properties"] as? [String: Any] ?? [:])
            }
        }

        // MARK: - SR44 supersede analytics

        @Test("displayed nudge superseded by a test → CEP superseded + Digia dismiss with dwell")
        func displayedNudgeSuperseded() async throws {
            let sdk = try await makeSdk([nudgeJson("real")])
            let real = deliver(sdk, "real", "cep-1")
            sdk.reportNudgeImpression()
            #expect(try await digiaEvents(sdk).map(\.name).contains("Digia Experience Viewed"))

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(real.dismissReason == .superseded)
            let all = try await digiaEvents(sdk)
            let dismissed = all.filter { $0.name == "Digia Experience Dismissed" }
            #expect(dismissed.count == 1)
            #expect(dismissed.first?.props["dwell_ms"] != nil)
        }

        @Test("never-displayed nudge superseded by a test → CEP superseded only, no Digia dismiss")
        func undisplayedNudgeSuperseded() async throws {
            let sdk = try await makeSdk([nudgeJson("real")])
            let real = deliver(sdk, "real", "cep-1")

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(real.dropReason == .superseded)
            #expect(real.isHoldReleased)
            let names = try await digiaEvents(sdk).map(\.name)
            #expect(names.contains("Digia Experience Viewed") == false)
            #expect(!names.contains("Digia Experience Dismissed"))
            #expect(sdk.controller.activeNudge?.payload.cepCampaignId == liveTestCepId("inv-1"))
        }

        @Test("displayed guide superseded by a test → CEP superseded + Digia dismiss")
        func displayedGuideSuperseded() async throws {
            let sdk = try await makeSdk([guideJson("g")])
            let guide = deliver(sdk, "g", "cep-1")
            sdk.reportGuideShown()

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(guide.dismissReason == .superseded)
            #expect(sdk.guideOrchestrator.state == nil)
            let all = try await digiaEvents(sdk)
            let dismissed = all.filter { $0.name == "Digia Experience Dismissed" }
            #expect(dismissed.count == 1)
            #expect(dismissed.first?.props["dismiss_reason"] as? String == "superseded")
        }

        @Test("never-displayed guide superseded by a test → CEP superseded only")
        func undisplayedGuideSuperseded() async throws {
            let sdk = try await makeSdk([guideJson("g")])
            let guide = deliver(sdk, "g", "cep-1")

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(guide.dropReason == .superseded)
            #expect(sdk.guideOrchestrator.state == nil)
            let names = try await digiaEvents(sdk).map(\.name)
            #expect(!names.contains("Digia Experience Dismissed"))
            #expect(!names.contains("Digia Step Dismissed"))
        }

        // MARK: - SR48 precondition before displacement

        @Test("a test that fails a config precondition leaves the occupant on screen")
        func liveTestFailingConfigKeepsOccupant() async throws {
            let sdk = try await makeSdk([nudgeJson("real")])
            let real = deliver(sdk, "real", "cep-1")

            // Not an RN app, so a guide with no canvas steps is invalid_config.
            liveTest(sdk, "inv-1", classicGuideJson("t1"))

            #expect(!real.isSettled)
            #expect(sdk.controller.activeNudge?.payload.campaignKey == "real")
        }

        // MARK: - SR43 same-campaign redelivery

        @Test("same campaign redelivered to its displayed slot → dropped quietly, never to HealthSink")
        func sameCampaignRedelivery() async throws {
            let recorder = TimelineCapture()
            DigiaLogger.registerSink(recorder)
            defer { DigiaLogger.unregisterSink(recorder) }
            let sdk = try await makeSdk([inlineJson("i1")])
            let first = deliver(sdk, "i1", "cep-1")
            sdk.reportSlotFirstRender(first.payload)

            let again = deliver(sdk, "i1", "cep-2")

            #expect(!first.isSettled)
            #expect(again.outcome == .dropped(reason: .surfaceBusy, detail: "same campaign already in slot"))
            #expect(sdk.inlineController.getCampaign("home_hero")?.cepCampaignId == first.payload.cepCampaignId)

            var record: TimelineRecord?
            for _ in 0..<50 where record == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
                record = recorder.records.first {
                    $0.reason?.wire == "surface_busy" && $0.campaignKey == "i1"
                }
            }
            let busy = try #require(record)
            #expect(busy.extras["blocking_campaign_key"] == nil)
            #expect(!HealthSink().accepts(busy))
        }

        @Test("same campaign over a never-displayed occupant → the normal replace")
        func sameCampaignReplacesUndisplayed() async throws {
            let sdk = try await makeSdk([inlineJson("i1")])
            let first = deliver(sdk, "i1", "cep-1")

            let again = deliver(sdk, "i1", "cep-2")

            #expect(first.dropReason == .superseded)
            #expect(!again.isSettled)
        }
    }
}

private final class TimelineCapture: DiagnosticSink, @unchecked Sendable {
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
