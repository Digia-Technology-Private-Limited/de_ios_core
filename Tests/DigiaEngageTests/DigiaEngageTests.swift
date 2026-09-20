import Combine
import Foundation
import SwiftUI
@testable import DigiaEngage
import Testing

@MainActor
@Suite("DigiaEngage", .serialized)
struct DigiaEngageTests {
    @Test("defaults config to production, with the auto log level")
    func defaultsConfig() {
        let config = DigiaConfig(apiKey: "prod_123")

        #expect(config.apiKey == "prod_123")
        // An unset level is debug-loud / release-quiet, and records that the
        // app did not choose it — the whole answer to a "nothing shows up"
        // ticket. See `DigiaLogLevel.auto`.
        #expect(config.logLevel == DigiaLogLevel.resolvedAuto)
        #expect(config.isLogLevelExplicit == false)
        #expect(config.environment == .production)
    }

    @Test("initialize is idempotent")
    func initializeIsIdempotent() async {
        let first = DigiaConfig(apiKey: "first")
        let second = DigiaConfig(apiKey: "second", environment: .sandbox)
        SDKInstance.shared.resetForTesting()

        // Seed config synchronously to avoid a network-call suspension point that would
        // allow concurrent tests to interfere via resetForTesting().
        SDKInstance.shared.markInitializedForTesting(with: first)

        // A second initialize call should hit the guard and return immediately (no await inside).
        try? await Digia.initialize(second)

        #expect(SDKInstance.shared.config == first)
    }

    @Test("register replaces and detaches the previous plugin")
    func registerReplacesPlugin() {
        SDKInstance.shared.resetForTesting()
        let first = TestPlugin(id: "first")
        let second = TestPlugin(id: "second")

        Digia.register(first)
        Digia.register(second)

        #expect(first.detachCount == 1)
        #expect(first.attachCount == 1)
        #expect(second.attachCount == 1)
        #expect(second.detachCount == 0)
    }

    @Test("G6 — the outgoing plugin's presentations settle before it detaches")
    func detachSettlesOwnedPresentationsFirst() throws {
        SDKInstance.shared.resetForTesting()
        let first = TestPlugin(id: "first")
        Digia.register(first)
        let campaign = try #require(nudgeCampaign(key: "global-nudge"))
        SDKInstance.shared.setCampaignsForTesting([campaign])
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "nudge-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        #expect(!recorder.isSettled)

        // The plugin learns it is going away *after* its presentations ended, so
        // its outcome handlers still run while its bridge is alive. Reversing
        // those two lines is the leak G6 exists to close.
        var settledAtDetach: Bool?
        first.onDetach = { settledAtDetach = recorder.isSettled }

        Digia.register(TestPlugin(id: "second"))

        #expect(settledAtDetach == true)
        #expect(recorder.dropReason == .pluginDetached)
        #expect(recorder.isHoldReleased)
        #expect(first.detachCount == 1)
    }

    @Test("deliver routes inline carousel campaigns into the inline controller")
    func routesInlineCarouselCampaignsIntoInlineController() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(CampaignModel.fromJson([
            "id": "carousel-id",
            "campaignKey": "carousel-campaign",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "hero_banner",
                "items": [["imageUrl": "https://example.com/a.png"]],
            ],
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])

        _ = SDKInstance.shared.deliver(
            CEPTriggerPayload(cepCampaignId: "carousel-campaign", campaignKey: "carousel-campaign", cepMetadata: [:]))

        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner")?.cepCampaignId == "carousel-campaign")
        #expect(SDKInstance.shared.inlineController.getCarouselConfig("hero_banner")?.items.count == 1)
    }

    @Test("campaign target screens are parsed")
    func parsesCampaignTargetScreens() throws {
        let campaign = try #require(CampaignModel.fromJson([
            "id": "targeted-id",
            "campaignKey": "help-inline",
            "campaignType": "inline",
            "targetScreenNames": ["names": ["Help", "Home"]],
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "hero_banner",
                "items": [["imageUrl": "https://example.com/a.png"]],
            ],
        ]))

        #expect(campaign.targetScreenNames == ["Help", "Home"])
    }

    @Test("campaign screen matching is case sensitive")
    func rejectsCampaignOnNonTargetedScreen() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(CampaignModel.fromJson([
            "id": "targeted-id",
            "campaignKey": "help-inline",
            "campaignType": "inline",
            "targetScreenNames": ["names": ["Help"]],
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "hero_banner",
                "items": [["imageUrl": "https://example.com/a.png"]],
            ],
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])
        SDKInstance.shared.setCurrentScreen("help")

        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:])))

        #expect(recorder.dropReason == .screenNotTargeted)
        #expect(recorder.isHoldReleased)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("targeted campaign is rejected when current screen is unset")
    func rejectsTargetedCampaignWhenScreenIsUnset() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(targetedInlineCampaign())
        SDKInstance.shared.campaignStore.populate([campaign])

        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:])))

        #expect(recorder.dropReason == .screenNotTargeted)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("latest trimmed screen name wins and navigation does not dismiss inline content")
    func usesLatestScreenWithoutDismissingAcceptedContent() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(targetedInlineCampaign())
        SDKInstance.shared.campaignStore.populate([campaign])
        SDKInstance.shared.setCurrentScreen("Home")
        SDKInstance.shared.setCurrentScreen(" Help ")

        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:])))
        SDKInstance.shared.setCurrentScreen("Home")

        #expect(!recorder.isSettled)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner")?.cepCampaignId == "ct-1")
    }

    @Test("screen changes dismiss an accepted targeted nudge")
    func screenChangesDismissTargetedNudge() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedNudgeCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")

        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "nudge-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.setCurrentScreen(" Help ")
        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "nudge-1")
        #expect(!recorder.isSettled)

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(SDKInstance.shared.controller.activeNudge == nil)
        // It never reported itself visible, so leaving the screen is a drop, not
        // a dismissal — `dismissed` would claim an impression that never was.
        #expect(recorder.dropReason == .cancelled)
        #expect(recorder.isHoldReleased)
    }

    @Test("screen change dismisses the old campaign before forwarding the new screen")
    func dismissesBeforeForwardingScreen() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let helpCampaign = try #require(nudgeCampaign(
            key: "help-nudge", targetScreenNames: ["Help"]))
        let homeCampaign = try #require(nudgeCampaign(
            key: "home-nudge", targetScreenNames: ["Home"]))
        SDKInstance.shared.setCampaignsForTesting([helpCampaign, homeCampaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let helpRecorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "help-1", campaignKey: helpCampaign.campaignKey,
                    cepMetadata: [:])))
        plugin.onForwardScreen = { screen in
            if screen == "Home" {
                _ = SDKInstance.shared.deliver(
                    CEPTriggerPayload(
                        cepCampaignId: "home-1",
                        campaignKey: homeCampaign.campaignKey,
                        cepMetadata: [:]))
            }
        }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(helpRecorder.isSettled)
        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "home-1")
    }

    @Test("same-screen reentrancy dismisses once and forwards once")
    func reentrantScreenChangeIsSafe() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedNudgeCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "nudge-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        var reentered = false
        // Re-entered the moment the nudge leaves the screen — the same instant
        // v1's `notifyEvent(.dismissed)` used to hand control back to a plugin.
        // v2 settles the outcome on a promise instead, so the surface's own
        // publisher is now the earliest synchronous observation point there is.
        let reentry = SDKInstance.shared.controller.$activeNudge.sink { nudge in
            guard nudge == nil, !reentered else { return }
            reentered = true
            SDKInstance.shared.setCurrentScreen("Home")
        }
        defer { reentry.cancel() }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(reentered)
        #expect(recorder.isSettled)
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        #expect(plugin.forwardedScreens.filter { $0 == "Home" }.count == 1)
    }

    @Test("screen changes keep an accepted global nudge")
    func screenChangesKeepGlobalNudge() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(nudgeCampaign(key: "global-nudge"))
        SDKInstance.shared.setCampaignsForTesting([campaign])
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "global-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "global-1")
        #expect(!recorder.isSettled)
    }

    @Test("screen changes dismiss an accepted targeted guide")
    func screenChangesDismissTargetedGuide() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "guide-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
        #expect(recorder.isSettled)
        #expect(recorder.isHoldReleased)
    }

    @Test("screen changes dismiss an accepted externally rendered guide")
    func screenChangesDismissExternalGuide() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        var renderRequested = false
        Digia.register(plugin)
        SDKInstance.shared.onGuideRenderRequest = { _, _ in renderRequested = true }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(renderRequested)
        #expect(recorder.isSettled)
        #expect(recorder.isHoldReleased)
    }

    @Test("stale terminal event does not disarm a newer external guide")
    func staleTerminalEventKeepsNewExternalGuideActive() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        SDKInstance.shared.onGuideRenderRequest = { _, _ in }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        _ = SDKInstance.shared.deliver(
            CEPTriggerPayload(
                cepCampaignId: "old-guide", campaignKey: campaign.campaignKey, cepMetadata: [:]))
        let newGuide = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "new-guide", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.captureAnalyticsEvent(
            campaignKey: campaign.campaignKey,
            eventName: "Digia Experience Dismissed",
            props: ["payload_id": "old-guide", "step_index": 1, "step_total": 1])
        SDKInstance.shared.captureAnalyticsEvent(
            campaignKey: campaign.campaignKey,
            eventName: "Digia Experience Dismissed",
            props: ["step_index": 1, "step_total": 1])
        SDKInstance.shared.setCurrentScreen("Home")

        #expect(newGuide.isSettled)
        #expect(newGuide.isHoldReleased)
    }

    @Test("onGuideRenderRequest hands the RN bridge the real presentation id")
    func guideRenderRequestReceivesRealPresentationId() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        SDKInstance.shared.markInitializedForTesting(
            with: DigiaConfig(apiKey: "test", wrapperBinding: "react_native"))
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        var receivedId: String?
        SDKInstance.shared.onGuideRenderRequest = { _, presentationId in receivedId = presentationId }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-id-check", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        let id = try #require(receivedId)
        #expect(!id.isEmpty)
        #expect(id == recorder.presentation.id)
    }

    @Test("reportExternalGuideLifecycle drives markDisplaying, emitClicked and settle on the real controller")
    func reportExternalGuideLifecycleDrivesRealController() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        SDKInstance.shared.markInitializedForTesting(
            with: DigiaConfig(apiKey: "test", wrapperBinding: "react_native"))
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        var presentationId: String?
        SDKInstance.shared.onGuideRenderRequest = { _, id in presentationId = id }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-verbs", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        let id = try #require(presentationId)

        #expect(!recorder.displayed)
        SDKInstance.shared.reportExternalGuideLifecycle(presentationId: id, event: .displaying)
        #expect(recorder.displayed)
        #expect(!recorder.isSettled)

        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id, event: .clicked(elementId: "primary-cta"))
        #expect(recorder.clickedElementIds == ["primary-cta"])
        #expect(!recorder.isSettled)

        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id, event: .settled(.dismissed(reason: .ctaAction, completed: true)))
        #expect(recorder.isSettled)
        #expect(recorder.isHoldReleased)
        #expect(recorder.dismissReason == .ctaAction)
    }

    @Test("reportExternalGuideLifecycle settles dropped for a presentation that never displayed")
    func reportExternalGuideLifecycleSettlesDropped() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        SDKInstance.shared.markInitializedForTesting(
            with: DigiaConfig(apiKey: "test", wrapperBinding: "react_native"))
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        var presentationId: String?
        SDKInstance.shared.onGuideRenderRequest = { _, id in presentationId = id }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-dropped", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        let id = try #require(presentationId)

        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id,
            event: .settled(.dropped(reason: .invalidConfig, detail: "js declined to render")))

        #expect(recorder.isSettled)
        #expect(recorder.isHoldReleased)
        #expect(recorder.dropReason == .invalidConfig)
        #expect(!recorder.displayed)
    }

    @Test("Digia.reportExternalGuideLifecycle hops off-main-thread calls onto the real controller")
    func digiaReportExternalGuideLifecycleHopsToMainActor() async throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        SDKInstance.shared.markInitializedForTesting(
            with: DigiaConfig(apiKey: "test", wrapperBinding: "react_native"))
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        var presentationId: String?
        SDKInstance.shared.onGuideRenderRequest = { _, id in presentationId = id }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-public-api", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        let id = try #require(presentationId)

        // The public entry point is `nonisolated` and hops via its own
        // `Task { @MainActor in ... }` rather than requiring the caller to
        // already be on the main actor — mirrors an `@objc` RN method arriving
        // on the JS thread. Give that hop a couple of turns before asserting.
        Digia.reportExternalGuideLifecycle(presentationId: id, event: .displaying)
        await Task.yield()
        await Task.yield()

        #expect(recorder.displayed)
    }

    @Test("reportExternalGuideLifecycle is a silent no-op for an unknown or already-settled id")
    func reportExternalGuideLifecycleNoOpForStaleId() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }

        // Never minted by any delivery — must not crash and must change nothing.
        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: "not-a-real-presentation-id", event: .displaying)
        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: "not-a-real-presentation-id",
            event: .settled(.dismissed(reason: .userClose, completed: false)))

        // A real id, but reported against again after it already settled — the
        // Metro-reload race the RN bridge is built to survive.
        SDKInstance.shared.markInitializedForTesting(
            with: DigiaConfig(apiKey: "test", wrapperBinding: "react_native"))
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        var presentationId: String?
        SDKInstance.shared.onGuideRenderRequest = { _, id in presentationId = id }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "rn-guide-stale", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        let id = try #require(presentationId)

        SDKInstance.shared.reportExternalGuideLifecycle(presentationId: id, event: .displaying)
        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id, event: .settled(.dismissed(reason: .userClose, completed: false)))
        #expect(recorder.isSettled)
        #expect(recorder.dismissReason == .userClose)

        // The stale report a Metro reload sends after native already settled on
        // its own: a different (wrong) reason, which must never overwrite the
        // real one.
        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id, event: .clicked(elementId: "late-tap"))
        SDKInstance.shared.reportExternalGuideLifecycle(
            presentationId: id, event: .settled(.dismissed(reason: .ctaAction, completed: true)))

        #expect(recorder.dismissReason == .userClose)
        #expect(recorder.clickedElementIds.isEmpty)
    }

    @Test("anchorless guide completion sends no click to the CEP")
    func anchorlessGuideCompletionStaysOutOfCepClicks() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(anchorlessGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "anchorless-guide", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        #expect(!recorder.isSettled)
        SDKInstance.shared.reportGuideShown()
        SDKInstance.shared.advanceGuide()
        SDKInstance.shared.reportGuideStepClicked(
            actionType: "dismiss",
            actionUrl: nil,
            ctaLabel: "Close",
            action: .dismiss,
            elementId: "primary"
        )
        SDKInstance.shared.dismissGuide()

        #expect(recorder.signals == [.displayed])
        #expect(recorder.dismissReason == .userClose)
    }

    @Test("screen changes dismiss an accepted targeted survey")
    func screenChangesDismissTargetedSurvey() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedSurveyCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "survey-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(SDKInstance.shared.surveyOrchestrator.state == nil)
        #expect(recorder.isSettled)
        #expect(recorder.isHoldReleased)
    }

    @Test("reentrant screen change dismisses a survey once")
    func reentrantScreenChangeDismissesSurveyOnce() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(id: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedSurveyCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "survey-1", campaignKey: campaign.campaignKey,
                    cepMetadata: [:])))
        var reentered = false
        plugin.onForwardScreen = { _ in
            if !reentered {
                reentered = true
                SDKInstance.shared.setCurrentScreen("Home")
            }
        }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(reentered)
        #expect(recorder.isSettled)
        #expect(SDKInstance.shared.surveyOrchestrator.state == nil)
    }

    @Test("campaign-key inline story payloads route into the inline controller")
    func routesInlineStoryCampaignsIntoInlineController() throws {
        SDKInstance.shared.resetForTesting()

        let campaign = try #require(CampaignModel.fromJson([
            "id": "story-campaign-id",
            "campaignKey": "story-campaign",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "story",
                "slotKey": "story_strip",
                "items": [
                    [
                        "type": "image",
                        "url": "https://example.com/story.png",
                        "duration": 3000,
                    ]
                ],
            ],
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])

        _ = SDKInstance.shared.deliver(
            CEPTriggerPayload(cepCampaignId: "story-campaign", campaignKey: "story-campaign", cepMetadata: [:]))

        #expect(SDKInstance.shared.inlineController.getCampaign("story_strip")?.cepCampaignId == "story-campaign")
        #expect(SDKInstance.shared.inlineController.getStoryConfig("story_strip")?.items.count == 1)
        #expect(SDKInstance.shared.inlineController.getCarouselConfig("story_strip") == nil)
    }

    @Test("the owner cancelling a presentation clears matching inline payloads")
    func invalidationClearsMatchingPayloads() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(CampaignModel.fromJson([
            "id": "carousel-id",
            "campaignKey": "carousel-campaign",
            "campaignType": "inline",
            "templateConfig": [
                "templateType": "carousel",
                "slotKey": "hero_banner",
                "items": [["imageUrl": "https://example.com/a.png"]],
            ],
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])

        let recorder = PresentationRecorder(
            SDKInstance.shared.deliver(
                CEPTriggerPayload(
                    cepCampaignId: "carousel-campaign", campaignKey: "carousel-campaign",
                    cepMetadata: [:])))
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") != nil)

        // v1's `onCampaignInvalidated(campaignID)` — now only the owner of the
        // handle can do it, which is the point of the two faces.
        recorder.presentation.cancel()

        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
        #expect(recorder.dropReason == .cancelled)
        #expect(recorder.isHoldReleased)
    }

    @Test("campaign parser accepts Android templateConfig survey key")
    func campaignParserAcceptsAndroidTemplateTypeSurveyKey() throws {
        let campaign = try #require(CampaignModel.fromJson([
            "id": "campaign-123",
            "campaignKey": "welcome_survey",
            "campaignType": "survey",
            "templateConfig": minimalSurveyTemplate(),
        ]))

        #expect(campaign.campaignType == "survey")
        let config = try #require(campaign.surveyConfig)
        #expect(config.nodes.count == 1)
        #expect(config.blocks.contains { $0.id == "block-1" })
    }

    @Test("campaign key payload routes through fetched survey campaign")
    func campaignKeyPayloadRoutesThroughFetchedSurveyCampaign() {
        SDKInstance.shared.resetForTesting()
        let campaign = try! #require(CampaignModel.fromJson([
            "id": "campaign-123",
            "campaignKey": "welcome_survey",
            "campaignType": "survey",
            "templateConfig": minimalSurveyTemplate(),
        ]))
        SDKInstance.shared.setCampaignsForTesting([campaign])

        _ = SDKInstance.shared.deliver(
            CEPTriggerPayload(cepCampaignId: "bridge-event", campaignKey: "welcome_survey", cepMetadata: [:]))

        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.cepCampaignId == "bridge-event")
        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.campaignKey == "welcome_survey")
    }

    @Test("classic inline exceptions do not turn item or canvas engagement into coarse clicks")
    func classicInlineClicksStaySeparateFromRichAnalytics() {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        Digia.register(TestPlugin(id: "plugin"))
        let recorder = PresentationRecorder(
            payload: CEPTriggerPayload(
                cepCampaignId: "inline", campaignKey: "inline", cepMetadata: [:]))
        let payload = recorder.payload

        SDKInstance.shared.reportStoryOpened(payload)
        SDKInstance.shared.reportStoryStepClicked(
            payload, itemIndex: 1, ctaLabel: "Continue", actionType: "openUrl", actionUrl: nil)
        SDKInstance.shared.reportCarouselStepClicked(payload: payload, itemIndex: 1, action: nil)
        SDKInstance.shared.reportBannerClicked(payload: payload, action: nil)
        SDKInstance.shared.reportPrimaryCTAClick(payload: payload, elementId: "secondary", isPrimary: false)
        #expect(recorder.signals.isEmpty)

        SDKInstance.shared.reportClassicStoryOpened(payload)
        SDKInstance.shared.reportClassicCarouselContainerClicked(payload)
        SDKInstance.shared.reportPrimaryCTAClick(payload: payload, elementId: "primary", isPrimary: true)
        // A click promotes a presentation that never reported an impression, so
        // G3's "displayed first" holds for the plugin either way.
        #expect(recorder.displayed)
        #expect(recorder.clickedElementIds == [
            "story_thumbnail", "carousel_container", "primary",
        ])
    }

    @Test("survey automatic engagement and completion do not emit its physical Start click")
    func surveyStartClickIsSeparateFromAutomaticEngagement() throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        Digia.register(TestPlugin(id: "plugin"))
        let campaign = try #require(targetedSurveyCampaign())
        let config = try #require(campaign.surveyConfig)
        let recorder = PresentationRecorder(
            payload: CEPTriggerPayload(
                cepCampaignId: "survey", campaignKey: campaign.campaignKey, cepMetadata: [:]),
            kind: .modal)
        #expect(SDKInstance.shared.surveyOrchestrator.start(
            payload: recorder.payload, config: config))

        SDKInstance.shared.reportSurveyWelcomeStart()
        SDKInstance.shared.reportSurveyQuestionSkipped(nodeId: "node-1", itemIndex: 1)
        SDKInstance.shared.reportSurveyCompleted(response: [:])
        #expect(recorder.clickedElementIds.isEmpty)

        SDKInstance.shared.reportSurveyStartClicked()
        #expect(recorder.clickedElementIds == ["welcome_start"])
    }

    @Test("classic nudge CTA clicks use the parsed primary marker, not button style", arguments: ["bottom_sheet", "dialog"])
    func classicNudgeCTAClicks(displayType: String) throws {
        SDKInstance.shared.resetForTesting()
        defer { SDKInstance.shared.resetForTesting() }
        Digia.register(TestPlugin(id: "plugin"))
        let config = try #require(NudgeConfig.fromJson([
            "container": ["displayType": displayType],
            "layout": [
                "type": "digia/column", "props": [:],
                "children": [
                    ["type": "digia/button", "props": ["variant": "fill"]],
                    ["type": "digia/button", "props": ["variant": "fill", "isPrimary": false]],
                    ["type": "digia/button", "props": ["variant": "text", "isPrimary": true]],
                ],
            ],
        ]))
        let recorder = PresentationRecorder(
            payload: CEPTriggerPayload(
                cepCampaignId: "nudge", campaignKey: "nudge", cepMetadata: [:]),
            kind: .modal)
        let payload = recorder.payload
        SDKInstance.shared.controller.showNudge(
            DigiaNudgePresentation(config: config, payload: payload, variables: nil))

        SDKInstance.shared.reportPrimaryCTAClick(elementId: "secondary", isPrimary: false)
        #expect(recorder.clickedElementIds.isEmpty)
        let buttons = config.layout.children.compactMap { node -> NudgeButton? in
            if case .button(let button) = node { return button }
            return nil
        }
        #expect(buttons.map(\.isPrimary) == [false, false, true])
        for button in buttons {
            SDKInstance.shared.reportPrimaryCTAClick(elementId: "cta_primary", isPrimary: button.isPrimary)
        }
        #expect(recorder.clickedElementIds == ["cta_primary"])

        let canvasConfig = try #require(NudgeConfig.fromJson([
            "container": ["displayType": displayType],
            "layoutMode": "canvas",
            "canvas": ["version": 2, "canvasWidth": 360, "canvasHeight": 180, "children": []],
        ]))
        SDKInstance.shared.controller.showNudge(
            DigiaNudgePresentation(config: canvasConfig, payload: payload, variables: nil))
        SDKInstance.shared.reportPrimaryCTAClick(elementId: "secondary", isPrimary: false)
        #expect(recorder.clickedElementIds.count == 1)
        SDKInstance.shared.reportPrimaryCTAClick(elementId: "primary", isPrimary: true)
        #expect(recorder.clickedElementIds == ["cta_primary", "primary"])
    }
}

@Suite("EngageActionParser")
struct EngageActionParserTests {
    private func onClick(_ steps: [[String: Any]]) -> [String: Any] { ["steps": steps] }

    @Test("parses open url and deeplink by launch mode")
    func parsesUrls() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.openUrl", "data": ["url": "https://x/y", "launchMode": "externalApplication"]],
            ["type": "Action.openUrl", "data": ["url": "app://path", "launchMode": "platformDefault"]],
        ]))
        #expect(actions == [.openUrl("https://x/y"), .openDeeplink("app://path")])
    }

    @Test("parses copy to clipboard from message")
    func parsesCopy() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": ["message": "PROMO50"]],
        ]))
        #expect(actions == [.copyToClipboard("PROMO50")])
    }

    @Test("parses share from message")
    func parsesShare() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.share", "data": ["message": "check this out"]],
        ]))
        #expect(actions == [.share("check this out")])
    }

    @Test("text payload falls back to text then value keys")
    func textFallbacks() {
        let fromText = EngageActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": ["text": "A"]],
        ]))
        let fromValue = EngageActionParser().parse(onClick([
            ["type": "Action.share", "data": ["value": "B"]],
        ]))
        #expect(fromText == [.copyToClipboard("A")])
        #expect(fromValue == [.share("B")])
    }

    @Test("blank or missing text drops copy and share")
    func dropsBlank() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": [:]],
            ["type": "Action.share", "data": ["message": ""]],
        ]))
        #expect(actions.isEmpty)
    }

    @Test("dismiss for hide bottom sheet and dismiss dialog")
    func parsesDismiss() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.hideBottomSheet"],
            ["type": "Action.dismissDialog"],
        ]))
        #expect(actions == [.dismiss, .dismiss])
    }

    @Test("analytics classifies share and copy explicitly")
    func analyticsTypes() {
        #expect(EngageAction.share("message").analyticsType == "share")
        #expect(EngageAction.copyToClipboard("message").analyticsType == "copy")
    }

    @Test("Custom KV keeps only strings and resolves variables in keys and values")
    func customKVResolvesVariables() throws {
        let parsed = EngageActionParser().parse([
            "steps": [[
                "type": "Action.customKV",
                "data": ["payload": [
                    "redirectionType": "{{ destination_type }}",
                    "{{ dynamic_key }}": "dynamic value",
                    "redirectionParams": "{\"redirectionUrl\":\"{{ route }}\"}",
                    "empty": "",
                    "ignoredNumber": 42,
                ]],
            ]],
        ])
        let action = try #require(parsed.first)
        #expect(action == .customKV([
            "redirectionType": "{{ destination_type }}",
            "{{ dynamic_key }}": "dynamic value",
            "redirectionParams": "{\"redirectionUrl\":\"{{ route }}\"}",
            "empty": "",
        ]))
        #expect(action.resolved(with: VariableContext(
            values: [
                "destination_type": "SCREEN",
                "dynamic_key": "resolvedKey",
                "route": "brands",
            ],
            types: [:]
        )) == .customKV([
            "redirectionType": "SCREEN",
            "resolvedKey": "dynamic value",
            "redirectionParams": "{\"redirectionUrl\":\"brands\"}",
            "empty": "",
        ]))
    }

    @Test("parses only canonical Custom KV structures")
    func parsesCustomKVStructures() {
        let actions = EngageActionParser().parse(onClick([
            ["type": "Action.customKV", "data": ["payload": ["canonical": "yes"]]],
            ["type": "customKV", "data": ["payload": ["ignored": "yes"]]],
        ]))

        #expect(actions == [
            .customKV(["canonical": "yes"]),
        ])
    }

    @Test("Story parses legacy CTA directly into Engage actions")
    func storyParsesLegacyActions() throws {
        let item = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
            "ctaAction": ["type": "deepLink", "url": "app://legacy"],
        ]))

        #expect(item.actions == [.openDeeplink("app://legacy"), .dismiss])
    }

    @Test("Story explicit empty flow does not fall back to legacy CTA")
    func storyEmptyCanonicalFlowWins() throws {
        let item = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
            "ctaAction": [
                "type": "deepLink",
                "url": "app://legacy",
                "steps": [],
            ],
        ]))

        #expect(item.actions.isEmpty)
    }

    @Test("Story CTA accepts a numeric dashboard font weight")
    func storyCtaAcceptsNumericFontWeight() throws {
        let item = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
            "ctaFontWeight": 700,
        ]))

        #expect(item.ctaFontWeight == 700)
    }

    @Test("Survey CTA accepts a numeric dashboard font weight")
    func surveyCtaAcceptsNumericFontWeight() {
        let cta = CtaSettings.from(["fontWeight": .int(500)])

        #expect(cta.fontWeight == 500)
    }

    @Test("Carousel legacy deep link is parsed into Engage actions")
    func carouselParsesLegacyActions() throws {
        let config = try #require(InlineCarouselConfig.fromJson([
            "slotKey": "home",
            "items": [[
                "imageUrl": "https://example.com/card.png",
                "deepLink": "app://legacy",
            ]],
        ]))

        #expect(config.items.first?.actions == [.openDeeplink("app://legacy")])
    }
}

private func targetedInlineCampaign() -> CampaignModel? {
    CampaignModel.fromJson([
        "id": "targeted-id",
        "campaignKey": "help-inline",
        "campaignType": "inline",
        "targetScreenNames": ["names": ["Help"]],
        "templateConfig": [
            "templateType": "carousel",
            "slotKey": "hero_banner",
            "items": [["imageUrl": "https://example.com/a.png"]],
        ],
    ])
}

private func targetedNudgeCampaign() -> CampaignModel? {
    nudgeCampaign(key: "help-nudge", targetScreenNames: ["Help"])
}

private func nudgeCampaign(
    key: String,
    targetScreenNames: [String] = []
) -> CampaignModel? {
    CampaignModel.fromJson([
        "id": "\(key)-id",
        "campaignKey": key,
        "campaignType": "nudge",
        "targetScreenNames": ["names": targetScreenNames],
        "templateConfig": [
            "container": ["displayType": "dialog"],
            "layout": [
                "type": "digia/column",
                "props": [:],
                "children": [],
            ],
        ],
    ])
}

private func targetedGuideCampaign() -> CampaignModel? {
    CampaignModel.fromJson([
        "id": "help-guide-id",
        "campaignKey": "help-guide",
        "campaignType": "guide",
        "targetScreenNames": ["names": ["Help"]],
        "templateConfig": [
            "templateType": "tooltip",
            "steps": [[
                "id": "step-1",
                "anchorKey": "help-anchor",
                "title": "Help",
                "body": "Body",
            ]],
        ],
    ])
}

private func anchorlessGuideCampaign() -> CampaignModel? {
    CampaignModel.fromJson([
        "id": "anchorless-guide-id",
        "campaignKey": "anchorless-guide",
        "campaignType": "guide",
        "templateConfig": [
            "templateType": "spotlight",
            "steps": [1, 2].map { step in
                [
                    "stepId": "step-\(step)",
                    "target": ["type": "anchorless", "version": 1, "pageKey": "home"],
                    "layoutMode": "canvas",
                    "canvas": [
                        "version": 2,
                        "canvasWidth": 240,
                        "canvasHeight": 120,
                        "children": [],
                    ],
                ] as [String: Any]
            },
        ],
    ])
}

private func targetedSurveyCampaign() -> CampaignModel? {
    CampaignModel.fromJson([
        "id": "help-survey-id",
        "campaignKey": "help-survey",
        "campaignType": "survey",
        "targetScreenNames": ["names": ["Help"]],
        "templateConfig": minimalSurveyTemplate(),
    ])
}

private func minimalSurveyTemplate() -> [String: Any] {
    // A welcome block is intro chrome (filtered from the node flow), so the
    // survey also needs at least one real question block + node to be valid.
    [
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
            ],
        ],
        "nodes": [
            [
                "id": "node-1",
                "blockId": "block-1",
            ],
        ],
    ]
}

private final class TestPlugin: DigiaCEPPlugin {
    let id: String
    var attachCount = 0
    var detachCount = 0
    var forwardedScreens: [String] = []
    private(set) var host: DigiaCEPHost?
    var onForwardScreen: ((String) -> Void)?
    var onDetach: (() -> Void)?

    init(id: String) {
        self.id = id
    }

    func attach(host: DigiaCEPHost) {
        attachCount += 1
        self.host = host
    }

    func onScreenChanged(_ screenName: String) {
        forwardedScreens.append(screenName)
        onForwardScreen?(screenName)
    }

    func detach() {
        detachCount += 1
        onDetach?()
        host = nil
    }
}
