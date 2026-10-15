import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: guides here drive AnchorRegistry.shared.
extension DigiaEngageTests {
    /// Round 3 of the surface rule (plan §8): PiP impression only when drawn
    /// (SR62), a never-displayed blocker not named (SR64), superseded survey
    /// fields (SR69), and `dismiss_reason` on nudge and survey (SR72).
    @MainActor
    @Suite("Surface rule round 3", .serialized)
    struct SurfaceRound3Tests {
        private func makeSdk(_ campaigns: [[String: Any]]) async throws -> SDKInstance {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            sdk.setCampaignsForTesting(try campaigns.map { try #require(try CampaignModel.fromJson($0)) })
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

        private func busyRecord(_ capture: RecordCapture, _ key: String) async throws -> TimelineRecord {
            var record: TimelineRecord?
            for _ in 0..<50 where record == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
                record = capture.records.first { $0.reason?.wire == "surface_busy" && $0.campaignKey == key }
            }
            return try #require(record)
        }

        // MARK: - SR62

        @Test("PiP media ready but never drawn → no impression; drawn → one impression")
        func pipImpressionOnlyWhenDrawn() async throws {
            let sdk = try await makeSdk([floaterJson("pip")])
            let pip = deliver(sdk, "pip", "cep-1")
            let token = try #require(sdk.floaterOrchestrator.state?.token)

            sdk.floaterOrchestrator.markVisible(token: token)
            #expect(!sdk.floaterOrchestrator.awaitingMedia)
            #expect(!(try await digiaEvents(sdk).map(\.name).contains("Digia Experience Viewed")))
            #expect(!pip.isHoldReleased)

            sdk.floaterOrchestrator.markDrawn(token: token)
            sdk.floaterOrchestrator.markDrawn(token: token)
            let viewed = try await digiaEvents(sdk).filter { $0.name == "Digia Experience Viewed" }
            #expect(viewed.count == 1)
            #expect(pip.isHoldReleased)
        }

        // MARK: - SR64

        @Test("a never-displayed blocker is not named; a displayed one is")
        func undisplayedBlockerNotNamed() async throws {
            let capture = RecordCapture()
            DigiaLogger.registerSink(capture)
            defer { DigiaLogger.unregisterSink(capture) }
            let sdk = try await makeSdk([nudgeJson("n1"), nudgeJson("n2"), nudgeJson("n3")])
            _ = deliver(sdk, "n1", "cep-1")

            _ = deliver(sdk, "n2", "cep-2")
            let undisplayed = try await busyRecord(capture, "n2")
            #expect(undisplayed.extras["blocking_campaign_key"] == nil)
            #expect(!HealthSink().accepts(undisplayed))

            sdk.reportNudgeImpression()
            _ = deliver(sdk, "n3", "cep-3")
            let displayed = try await busyRecord(capture, "n3")
            #expect(displayed.extras["blocking_campaign_key"] == "n1")
        }

        // MARK: - SR69

        @Test("a displayed survey superseded by a test sends the normal dismiss fields")
        func supersededSurveyFields() async throws {
            let sdk = try await makeSdk([surveyJson("s")])
            let survey = deliver(sdk, "s", "cep-1")
            let token = try #require(sdk.surveyOrchestrator.state?.token)
            sdk.surveyOrchestrator.bindProgress(token: token) { (2, 1) }
            sdk.reportSurveyStarted()

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(survey.dismissReason == .superseded)
            let dismissed = try await digiaEvents(sdk).filter { $0.name == "Digia Experience Dismissed" }
            #expect(dismissed.count == 1)
            let props = try #require(dismissed.first?.props)
            #expect(props["dismiss_reason"] as? String == "superseded")
            #expect(props["abandoned_at_item"] as? Int == 2)
            #expect(props["answered_count"] as? Int == 1)
            #expect(props["dwell_ms"] != nil)
        }

        // MARK: - SR72

        @Test("nudge dismiss carries the CEP's reason as dismiss_reason")
        func nudgeDismissReason() async throws {
            let sdk = try await makeSdk([nudgeJson("n")])
            let nudge = deliver(sdk, "n", "cep-1")
            sdk.reportNudgeImpression()

            sdk.markNudgeDismissed(reason: .ctaAction)

            #expect(nudge.dismissReason == .ctaAction)
            let dismissed = try await digiaEvents(sdk).filter { $0.name == "Digia Experience Dismissed" }
            #expect(dismissed.first?.props["dismiss_reason"] as? String == "cta_action")
        }

        @Test("a guide completed by its CTA → CEP completed, Digia Completed, no Digia dismiss (SR71)")
        func completedGuideSendsNoDismiss() async throws {
            var json = guideJson("g")
            var template = try #require(json["templateConfig"] as? [String: Any])
            var steps = try #require(template["steps"] as? [[String: Any]])
            var second = steps[0]
            second["stepId"] = "step-2"
            steps.append(second)
            template["steps"] = steps
            json["templateConfig"] = template
            let sdk = try await makeSdk([json])
            let guide = deliver(sdk, "g", "cep-1")
            sdk.reportGuideShown()

            sdk.advanceGuide()
            sdk.reportGuideShown()
            sdk.advanceGuide()

            #expect(guide.dismissReason == .completed)
            let names = try await digiaEvents(sdk).map(\.name)
            #expect(names.contains("Digia Experience Completed"))
            #expect(names.contains("Digia Experience Dismissed"))
            let dismissed = try await digiaEvents(sdk).first { $0.name == "Digia Experience Dismissed" }
            #expect(dismissed?.props["dismiss_reason"] as? String == "completed")
            #expect(dismissed?.props["dwell_ms"] != nil)
        }

        @Test("survey dismiss carries user_close; a completed survey sends Digia dismiss (SR71)")
        func surveyDismissReason() async throws {
            let sdk = try await makeSdk([surveyJson("s1"), surveyJson("s2")])
            let first = deliver(sdk, "s1", "cep-1")
            sdk.reportSurveyStarted()
            sdk.markSurveyDismissed(abandonedAtItem: 0, answeredCount: 0)
            #expect(first.dismissReason == .userClose)

            let second = deliver(sdk, "s2", "cep-2")
            sdk.reportSurveyStarted()
            sdk.markSurveyCompleted(response: [:])
            #expect(second.dismissReason == .completed)

            let reasons = try await digiaEvents(sdk)
                .filter { $0.name == "Digia Experience Dismissed" }
                .map { $0.props["dismiss_reason"] as? String }
            #expect(reasons == ["user_close", "completed"])
        }
    }
}

func surveyJson(_ key: String) -> [String: Any] {
    [
        "id": "\(key)-id",
        "campaignKey": key,
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
                ] as [String: Any]
            ],
            "nodes": [["id": "node-1", "blockId": "block-1"]],
        ] as [String: Any],
    ]
}

private final class RecordCapture: DiagnosticSink, @unchecked Sendable {
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
