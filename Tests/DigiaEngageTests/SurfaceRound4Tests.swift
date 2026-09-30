import Foundation
import Testing

@testable import DigiaEngage

// In the serialized DigiaEngage suite: guides here drive AnchorRegistry.shared.
extension DigiaEngageTests {
    /// Round 4 of the surface rule (plan §9): a showing RN classic guide disarms
    /// the acceptance watchdog (SR91), the foreground rule for HealthSink `timeout`
    /// (SR94), inline live tests keep 10 s (SR95), completed wins (SR96), the iOS
    /// small fixes (SR97) and survey screen-exit progress (SR100).
    @MainActor
    @Suite("Surface rule round 4", .serialized)
    struct SurfaceRound4Tests {
        private func makeSdk(
            _ campaigns: [[String: Any]], wrapperBinding: String? = nil
        ) async throws -> SDKInstance {
            let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
            let sdk = SDKInstance(
                defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() }
            )
            try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
            if let wrapperBinding {
                sdk.markInitializedForTesting(
                    with: DigiaConfig(apiKey: "test_key", wrapperBinding: wrapperBinding))
            }
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

        // MARK: - SR91

        @Test("a displayed classic guide never times out; a second guide is surface_busy")
        func classicGuideDisplayingDisarmsWatchdog() async throws {
            let sdk = try await makeSdk(
                [classicGuideJson("a"), classicGuideJson("b")], wrapperBinding: "react_native")
            sdk.coordinator = PresentationCoordinator(
                idGenerator: { UUID().uuidString }, onCancelSurface: { _ in }, acceptanceTimeout: 0.1)
            var ids: [String] = []
            sdk.onGuideRenderRequest = { ids.append($0.presentationId) }

            let first = deliver(sdk, "a", "cep-a")
            // An RN guide on screen is a guide occupant, so a second guide is busy.
            let second = deliver(sdk, "b", "cep-b")
            try #require(ids.count == 1)
            sdk.reportExternalGuideLifecycle(presentationId: ids[0], event: .displaying)
            try await Task.sleep(nanoseconds: 400_000_000)

            #expect(first.displayed)
            #expect(!first.isSettled)
            #expect(second.dropReason == .surfaceBusy)
        }

        // MARK: - SR94

        @Test("backgrounded during the window: settled and torn down, but no surface_kind")
        func backgroundedWindowSkipsHealth() async throws {
            var cancelled = 0
            let coordinator = PresentationCoordinator(
                idGenerator: { UUID().uuidString }, onCancelSurface: { _ in cancelled += 1 },
                acceptanceTimeout: 0.05)
            let away = coordinator.open(
                CEPTriggerPayload(cepCampaignId: "a", campaignKey: "a", cepMetadata: [:]), owner: "p")
            coordinator.accept(away, kind: .modal, surfaceKind: "nudge")
            coordinator.noteAppLeftForeground()
            coordinator.noteAppEnteredForeground()
            let stayed = coordinator.open(
                CEPTriggerPayload(cepCampaignId: "b", campaignKey: "b", cepMetadata: [:]), owner: "p")
            coordinator.accept(stayed, kind: .modal, surfaceKind: "nudge")

            for _ in 0..<500 where cancelled < 2 { try await Task.sleep(nanoseconds: 10_000_000) }

            #expect(cancelled == 2)
            #expect(away.presentation.outcome.settledValue
                == .dropped(reason: .timeout, detail: "never displayed within the acceptance window"))
            #expect(away.dropExtras == nil)
            #expect(stayed.dropExtras == ["surface_kind": "nudge"])
            let record = { (extras: [String: String]) in
                TimelineRecord(
                    timestamp: Date(), severity: .error, tag: "DIGIA", message: "Dropped — timeout",
                    stage: .render, reason: DropReason.timeout, campaignKey: "a", extras: extras)
            }
            #expect(!HealthSink().accepts(record(away.dropExtras ?? [:])))
            #expect(HealthSink().accepts(record(stayed.dropExtras ?? [:])))
        }

        // MARK: - SR95, R3-10

        @Test("the live-test watchdog re-arms at acceptance with no delay; inline gets 10 s")
        func liveTestRearmsForEveryKind() async throws {
            #expect(LiveTestContext.inlineWatchdogTimeout == 10)
            #expect(LiveTestContext.watchdogTimeout == 5)
            let reporter = LiveTestAckReporter(networkClient: MockNetworkClient())
            var fired = false
            let context = LiveTestContext(
                testInvocationId: "inv-1", reporter: reporter,
                onTerminal: { fired = true }, timeout: 0.05)
            context.delayWatchdog(by: 0, window: 0.6)

            try await Task.sleep(nanoseconds: 250_000_000)
            #expect(!fired)
            for _ in 0..<500 where !fired { try await Task.sleep(nanoseconds: 10_000_000) }
            #expect(fired)
            withExtendedLifetime(context) {}
        }

        // MARK: - SR96

        @Test("a guide completed by a CTA that stays up, then superseded → CEP completed, no Digia dismiss")
        func completedGuideSupersededSendsNoDismiss() async throws {
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
            // "Copy code" on the last step: completion fires, the guide stays up.
            sdk.reportGuideStepClicked(actionType: "copyToClipboard", actionUrl: nil, ctaLabel: "Copy")
            try #require(sdk.guideOrchestrator.state != nil)

            liveTest(sdk, "inv-1", nudgeJson("t1"))

            #expect(guide.outcome == .dismissed(reason: .completed, completed: true))
            let names = try await digiaEvents(sdk).map(\.name)
            #expect(names.contains("Digia Experience Completed"))
            #expect(!names.contains("Digia Experience Dismissed"))
            #expect(!names.contains("Digia Step Dismissed"))
        }

        // MARK: - SR97 R3-07

        @Test("tearing down a nudge leaves an inline slot that shares its CEP id")
        func teardownKeepsInlineWithSameId() async throws {
            let sdk = try await makeSdk([inlineJson("i"), nudgeJson("n")])
            let inline = deliver(sdk, "i", "same")
            try #require(sdk.inlineController.slotOccupants.count == 1)
            let nudge = deliver(sdk, "n", "same")
            try #require(sdk.controller.activeNudge != nil)

            nudge.presentation.cancel()

            #expect(sdk.controller.activeNudge == nil)
            #expect(sdk.inlineController.slotOccupants.count == 1)
            #expect(!inline.isSettled)
        }

        // MARK: - SR100

        @Test("a survey closed by a screen change carries its progress fields")
        func surveyScreenExitCarriesProgress() async throws {
            var json = surveyJson("s")
            json["targetScreenNames"] = ["names": ["A"]]
            let sdk = try await makeSdk([json])
            sdk.setCurrentScreen("A")
            let survey = deliver(sdk, "s", "cep-1")
            let token = try #require(sdk.surveyOrchestrator.state?.token)
            sdk.surveyOrchestrator.bindProgress(token: token) { (2, 1) }
            sdk.reportSurveyStarted()

            sdk.setCurrentScreen("B")

            #expect(survey.dismissReason == .screenExit)
            let dismissed = try await digiaEvents(sdk).filter { $0.name == "Digia Experience Dismissed" }
            let props = try #require(dismissed.first?.props)
            #expect(props["dismiss_reason"] as? String == "screen_exit")
            #expect(props["abandoned_at_item"] as? Int == 2)
            #expect(props["answered_count"] as? Int == 1)
        }
    }
}
