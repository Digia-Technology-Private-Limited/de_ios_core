import Foundation
import SwiftUI
@testable import DigiaEngage
import Testing

@MainActor
@Suite("DigiaEngage", .serialized)
struct DigiaEngageTests {
    @Test("defaults config to production error logging")
    func defaultsConfig() {
        let config = DigiaConfig(apiKey: "prod_123")

        #expect(config.apiKey == "prod_123")
        #expect(config.logLevel == .error)
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

    @Test("register replaces and tears down the previous plugin")
    func registerReplacesPlugin() {
        SDKInstance.shared.resetForTesting()
        let first = TestPlugin(identifier: "first")
        let second = TestPlugin(identifier: "second")

        Digia.register(first)
        Digia.register(second)

        #expect(first.teardownCount == 1)
        #expect(first.setupCount == 1)
        #expect(second.setupCount == 1)
        #expect(second.teardownCount == 0)
    }

    @Test("onCampaignTriggered routes inline carousel campaigns into the inline controller")
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

        SDKInstance.shared.onCampaignTriggered(
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

        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:]))

        #expect(!accepted)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("targeted campaign is rejected when current screen is unset")
    func rejectsTargetedCampaignWhenScreenIsUnset() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(targetedInlineCampaign())
        SDKInstance.shared.campaignStore.populate([campaign])

        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:]))

        #expect(!accepted)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("latest trimmed screen name wins and navigation does not dismiss inline content")
    func usesLatestScreenWithoutDismissingAcceptedContent() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(targetedInlineCampaign())
        SDKInstance.shared.campaignStore.populate([campaign])
        SDKInstance.shared.setCurrentScreen("Home")
        SDKInstance.shared.setCurrentScreen(" Help ")

        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "ct-1", campaignKey: "help-inline", cepMetadata: [:]))
        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner")?.cepCampaignId == "ct-1")
    }

    @Test("screen changes dismiss an accepted targeted nudge")
    func screenChangesDismissTargetedNudge() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedNudgeCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")

        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "nudge-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.setCurrentScreen(" Help ")
        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "nudge-1")
        #expect(!plugin.events.contains { $0.0 == .dismissed })

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "nudge-1"
        })
    }

    @Test("screen change dismisses the old campaign before forwarding the new screen")
    func dismissesBeforeForwardingScreen() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let helpCampaign = try #require(nudgeCampaign(
            key: "help-nudge", targetScreenNames: ["Help"]))
        let homeCampaign = try #require(nudgeCampaign(
            key: "home-nudge", targetScreenNames: ["Home"]))
        SDKInstance.shared.setCampaignsForTesting([helpCampaign, homeCampaign])
        SDKInstance.shared.setCurrentScreen("Help")
        _ = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "help-1", campaignKey: helpCampaign.campaignKey, cepMetadata: [:]))
        plugin.onForwardScreen = { screen in
            if screen == "Home" {
                _ = SDKInstance.shared.onCampaignTriggered(
                    CEPTriggerPayload(
                        cepCampaignId: "home-1",
                        campaignKey: homeCampaign.campaignKey,
                        cepMetadata: [:]))
            }
        }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "help-1"
        })
        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "home-1")
    }

    @Test("same-screen reentrancy dismisses once and forwards once")
    func reentrantScreenChangeIsSafe() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedNudgeCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        _ = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "nudge-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))
        var reentered = false
        plugin.onNotifyEvent = { event, _ in
            if event == .dismissed, !reentered {
                reentered = true
                SDKInstance.shared.setCurrentScreen("Home")
            }
        }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(plugin.events.filter { event, payload in
            event == .dismissed && payload.cepCampaignId == "nudge-1"
        }.count == 1)
        #expect(plugin.forwardedScreens.filter { $0 == "Home" }.count == 1)
    }

    @Test("screen changes keep an accepted global nudge")
    func screenChangesKeepGlobalNudge() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(nudgeCampaign(key: "global-nudge"))
        SDKInstance.shared.setCampaignsForTesting([campaign])
        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "global-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(SDKInstance.shared.controller.activeNudge?.payload.cepCampaignId == "global-1")
        #expect(!plugin.events.contains { $0.0 == .dismissed })
    }

    @Test("screen changes dismiss an accepted targeted guide")
    func screenChangesDismissTargetedGuide() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "guide-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "guide-1"
        })
    }

    @Test("screen changes dismiss an accepted externally rendered guide")
    func screenChangesDismissExternalGuide() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        var renderRequested = false
        Digia.register(plugin)
        SDKInstance.shared.onGuideRenderRequest = { _ in renderRequested = true }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "rn-guide-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(renderRequested)
        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "rn-guide-1"
        })
    }

    @Test("stale terminal event does not disarm a newer external guide")
    func staleTerminalEventKeepsNewExternalGuideActive() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        SDKInstance.shared.onGuideRenderRequest = { _ in }
        defer { SDKInstance.shared.onGuideRenderRequest = nil }
        let campaign = try #require(targetedGuideCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        _ = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "old-guide", campaignKey: campaign.campaignKey, cepMetadata: [:]))
        _ = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "new-guide", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.captureAnalyticsEvent(
            campaignKey: campaign.campaignKey,
            eventName: "Digia Experience Dismissed",
            props: ["payload_id": "old-guide", "step_index": 1, "step_total": 1])
        SDKInstance.shared.captureAnalyticsEvent(
            campaignKey: campaign.campaignKey,
            eventName: "Digia Experience Dismissed",
            props: ["step_index": 1, "step_total": 1])
        SDKInstance.shared.setCurrentScreen("Home")

        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "new-guide"
        })
    }

    @Test("screen changes dismiss an accepted targeted survey")
    func screenChangesDismissTargetedSurvey() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedSurveyCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        let accepted = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "survey-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(accepted)
        #expect(SDKInstance.shared.surveyOrchestrator.state == nil)
        #expect(plugin.events.contains { event, payload in
            event == .dismissed && payload.cepCampaignId == "survey-1"
        })
    }

    @Test("reentrant screen change dismisses a survey once")
    func reentrantScreenChangeDismissesSurveyOnce() throws {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        Digia.register(plugin)
        let campaign = try #require(targetedSurveyCampaign())
        SDKInstance.shared.setCampaignsForTesting([campaign])
        SDKInstance.shared.setCurrentScreen("Help")
        _ = SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(
                cepCampaignId: "survey-1", campaignKey: campaign.campaignKey, cepMetadata: [:]))
        var reentered = false
        plugin.onNotifyEvent = { event, _ in
            if event == .dismissed, !reentered {
                reentered = true
                SDKInstance.shared.setCurrentScreen("Home")
            }
        }

        SDKInstance.shared.setCurrentScreen("Home")

        #expect(plugin.events.filter { event, payload in
            event == .dismissed && payload.cepCampaignId == "survey-1"
        }.count == 1)
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

        SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(cepCampaignId: "story-campaign", campaignKey: "story-campaign", cepMetadata: [:]))

        #expect(SDKInstance.shared.inlineController.getCampaign("story_strip")?.cepCampaignId == "story-campaign")
        #expect(SDKInstance.shared.inlineController.getStoryConfig("story_strip")?.items.count == 1)
        #expect(SDKInstance.shared.inlineController.getCarouselConfig("story_strip") == nil)
    }

    @Test("onCampaignInvalidated clears matching inline payloads")
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

        SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(cepCampaignId: "carousel-campaign", campaignKey: "carousel-campaign", cepMetadata: [:]))
        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") != nil)

        SDKInstance.shared.onCampaignInvalidated("carousel-campaign")

        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == nil)
    }

    @Test("slot placeholder registration is delegated to the active plugin")
    func placeholderRegistrationDelegatesToPlugin() {
        SDKInstance.shared.resetForTesting()
        let plugin = TestPlugin(identifier: "plugin")
        plugin.placeholderIDToReturn = 42
        Digia.register(plugin)

        let id = SDKInstance.shared.registerPlaceholderForSlot(
            propertyID: "hero_banner"
        )

        #expect(id == 42)
        #expect(plugin.placeholderRegistrations.count == 1)
        #expect(plugin.placeholderRegistrations.first == "hero_banner")

        SDKInstance.shared.deregisterPlaceholderForSlot(42)
        #expect(plugin.deregisteredPlaceholderIDs == [42])
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

        SDKInstance.shared.onCampaignTriggered(
            CEPTriggerPayload(cepCampaignId: "bridge-event", campaignKey: "welcome_survey", cepMetadata: [:]))

        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.cepCampaignId == "bridge-event")
        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.campaignKey == "welcome_survey")
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
    let identifier: String
    var setupCount = 0
    var teardownCount = 0
    var placeholderIDToReturn: Int?
    var placeholderRegistrations: [String] = []
    var deregisteredPlaceholderIDs: [Int] = []
    var forwardedScreens: [String] = []
    var events: [(DigiaExperienceEvent, CEPTriggerPayload)] = []
    var onForwardScreen: ((String) -> Void)?
    var onNotifyEvent: ((DigiaExperienceEvent, CEPTriggerPayload) -> Void)?

    init(identifier: String) {
        self.identifier = identifier
    }

    func setup(delegate: DigiaCEPDelegate) {
        setupCount += 1
    }

    func forwardScreen(_ name: String) {
        forwardedScreens.append(name)
        onForwardScreen?(name)
    }

    func registerPlaceholder(propertyID: String) -> Int? {
        placeholderRegistrations.append(propertyID)
        return placeholderIDToReturn
    }

    func deregisterPlaceholder(_ id: Int) {
        deregisteredPlaceholderIDs.append(id)
    }

    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        events.append((event, payload))
        onNotifyEvent?(event, payload)
    }

    func healthCheck() -> DiagnosticReport {
        DiagnosticReport(isHealthy: true)
    }

    func teardown() {
        teardownCount += 1
    }
}
