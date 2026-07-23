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
        #expect(config.developerConfig == nil)
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

    @Test("latest trimmed screen name wins and navigation does not dismiss accepted content")
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

    @Test("Story thumbnail playback defaults preserve legacy simultaneous behavior")
    func storyThumbnailPlaybackDefaults() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .simultaneous)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 0)
        #expect(config.items[0].thumbnailPlayback.durationMode == .full)
        #expect(config.items[0].thumbnailPlayback.durationMs == nil)
    }

    @Test("Story thumbnail playback parses sequential fixed windows")
    func storyThumbnailPlaybackParsesSequentialFixedWindow() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "thumbnailVideoPlayback": "sequential",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
                "thumbnailPlayback": [
                    "startTimeMs": 42_000,
                    "durationMode": "fixed",
                    "durationMs": 5_000,
                ],
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .sequential)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 42_000)
        #expect(config.items[0].thumbnailPlayback.durationMode == .fixed)
        #expect(config.items[0].thumbnailPlayback.durationMs == 5_000)
    }

    @Test("Invalid story thumbnail values fall back safely")
    func storyThumbnailPlaybackRejectsInvalidValues() throws {
        let config = try #require(InlineStoryConfig.fromJson([
            "slotKey": "home",
            "thumbnailVideoPlayback": "future-mode",
            "items": [[
                "type": "video",
                "url": "https://example.com/story.mp4",
                "thumbnailPlayback": [
                    "startTimeMs": -1,
                    "durationMode": "fixed",
                    "durationMs": 0,
                ],
            ]],
        ]))

        #expect(config.thumbnailVideoPlayback == .simultaneous)
        #expect(config.items[0].thumbnailPlayback.startTimeMs == 0)
        #expect(config.items[0].thumbnailPlayback.durationMode == .full)
        #expect(config.items[0].thumbnailPlayback.durationMs == nil)
    }

    @Test("Story thumbnail eligibility uses 75/25 hysteresis")
    func storyThumbnailEligibilityUsesHysteresis() throws {
        let video = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
        ]))
        let image = try #require(StoryItemConfig.fromJson([
            "type": "image",
            "url": "https://example.com/story.png",
        ]))

        let entered = updateThumbnailPlaybackEligibility(
            current: [],
            visibleFractions: [0: 0.75, 1: 1],
            items: [video, image]
        )
        let retained = updateThumbnailPlaybackEligibility(
            current: entered,
            visibleFractions: [0: 0.50],
            items: [video, image]
        )
        let exited = updateThumbnailPlaybackEligibility(
            current: retained,
            visibleFractions: [0: 0.249],
            items: [video, image]
        )

        #expect(entered == [0])
        #expect(retained == [0])
        #expect(exited.isEmpty)
    }

    @Test("Story thumbnail helpers wrap and bound configured windows")
    func storyThumbnailPlaybackHelpers() throws {
        let item = try #require(StoryItemConfig.fromJson([
            "type": "video",
            "url": "https://example.com/story.mp4",
            "thumbnailPlayback": [
                "startTimeMs": 42_000,
                "durationMode": "fixed",
                "durationMs": 5_000,
            ],
        ]))

        #expect(nextThumbnailPlaybackIndex(eligible: [1, 3], afterIndex: 1) == 3)
        #expect(nextThumbnailPlaybackIndex(eligible: [1, 3], afterIndex: 3) == 1)
        #expect(effectiveThumbnailStartMs(item: item, naturalDurationMs: 40_000) == 0)
        #expect(thumbnailPlaybackWindowEnded(
            item: item,
            currentPositionMs: 47_000,
            effectiveStartMs: 42_000
        ))
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

    @Test("Guide explicit empty flow does not fall back to legacy action")
    func guideEmptyCanonicalFlowWins() throws {
        let config = GuideStepWidgetConfig.fromJson([
            "actions": [[
                "id": "continue",
                "type": "NEXT",
                "label": "Continue",
                "onClick": ["steps": []],
            ]],
        ])

        #expect(config.actions.first?.actions.isEmpty == true)
    }

    @Test("Guide parses flat dashboard typography including medium weight")
    func guideParsesFlatTypography() throws {
        let config = GuideStepWidgetConfig.fromJson([
            "title": "Welcome",
            "titleWeight": "500",
            "titleSize": 18,
            "titleColor": "#112233",
            "body": "Start here",
            "bodyWeight": 500,
            "bodySize": 15,
            "bodyColor": "#445566",
            "content": [
                "title": ["textStyle": ["textColor": "#FF0000"]],
                "body": ["textStyle": ["textColor": "#00FF00"]],
            ],
            "buttonPrimaryBackgroundColor": "#123456",
            "buttonPrimaryTextColor": "#FEDCBA",
            "actions": [[
                "id": "continue",
                "type": "NEXT",
                "label": "Continue",
                "fontSize": 16,
                "fontWeight": 700,
            ]],
        ])

        #expect(config.content.title?.fontWeight == 500)
        #expect(config.content.title?.text == "Welcome")
        #expect(config.content.title?.fontSize == 18)
        #expect(config.content.title?.textColor == "#112233")
        #expect(config.content.body?.fontSize == 15)
        #expect(config.content.body?.fontWeight == 500)
        #expect(config.content.body?.text == "Start here")
        #expect(config.content.body?.textColor == "#445566")
        #expect(config.actions.first?.fontSize == 16)
        #expect(config.actions.first?.fontWeight == 700)
        #expect(config.actions.first?.backgroundColor == "#123456")
        #expect(config.actions.first?.textColor == "#FEDCBA")
    }

    @Test("Guide keeps the legacy nested schema isolated from flat keys")
    func guideParsesLegacyNestedTypography() throws {
        let config = GuideStepWidgetConfig.fromJson([
            "titleColor": "#FF0000",
            "content": [
                "title": [
                    "text": "Legacy title",
                    "textStyle": [
                        "textColor": "#112233",
                        "fontToken": ["font": ["weight": "medium", "size": 18]],
                    ],
                ],
                "actions": [[
                    "id": "legacy-next",
                    "label": "Continue",
                    "action_type": "NEXT",
                    "background_color": "#334455",
                    "text_color": "#FFFFFF",
                    "corner_radius": 12,
                ]],
            ],
        ])

        #expect(config.content.title?.text == "Legacy title")
        #expect(config.content.title?.fontWeight == 500)
        #expect(config.content.title?.textColor == "#112233")
        #expect(config.actions.first?.actionType == .next)
        #expect(config.actions.first?.backgroundColor == "#334455")
        #expect(config.actions.first?.cornerRadius == 12)
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

    init(identifier: String) {
        self.identifier = identifier
    }

    func setup(delegate: DigiaCEPDelegate) {
        setupCount += 1
    }

    func forwardScreen(_ name: String) {
        forwardedScreens.append(name)
    }

    func registerPlaceholder(propertyID: String) -> Int? {
        placeholderRegistrations.append(propertyID)
        return placeholderIDToReturn
    }

    func deregisterPlaceholder(_ id: Int) {
        deregisteredPlaceholderIDs.append(id)
    }

    func notifyEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {}

    func healthCheck() -> DiagnosticReport {
        DiagnosticReport(isHealthy: true)
    }

    func teardown() {
        teardownCount += 1
    }
}
