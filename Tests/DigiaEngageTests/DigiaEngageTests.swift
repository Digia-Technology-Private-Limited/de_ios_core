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

    @Test("onCampaignTriggered routes inline payloads into the inline controller")
    func routesInlinePayloadsIntoInlineController() {
        SDKInstance.shared.resetForTesting()

        let payload = InAppPayload(
            id: "campaign-inline",
            content: InAppPayloadContent(
                type: "inline",
                placementKey: "hero_banner",
                title: "Inline title"
            )
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.inlineController.getCampaign("hero_banner") == payload)
        #expect(SDKInstance.shared.controller.activePayload == nil)
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

        let payload = InAppPayload(
            id: "story-campaign",
            content: InAppPayloadContent(type: "inline")
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.inlineController.getCampaign("story_strip")?.id == "story-campaign")
        #expect(SDKInstance.shared.inlineController.getStoryConfig("story_strip")?.items.count == 1)
        #expect(SDKInstance.shared.inlineController.getCarouselConfig("story_strip") == nil)
    }

    @Test("onCampaignTriggered routes modal payloads into the overlay controller")
    func routesModalPayloadsIntoOverlayController() {
        SDKInstance.shared.resetForTesting()

        let payload = InAppPayload(
            id: "campaign-modal",
            content: InAppPayloadContent(type: "dialog", title: "Modal title")
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.controller.activePayload == payload)
    }

    @Test("onCampaignInvalidated clears matching modal and inline payloads")
    func invalidationClearsMatchingPayloads() {
        SDKInstance.shared.resetForTesting()

        let modal = InAppPayload(
            id: "campaign-modal",
            content: InAppPayloadContent(type: "dialog")
        )
        let inline = InAppPayload(
            id: "campaign-inline",
            content: InAppPayloadContent(type: "inline", placementKey: "hero_banner")
        )

        SDKInstance.shared.onCampaignTriggered(modal)
        SDKInstance.shared.onCampaignTriggered(inline)
        SDKInstance.shared.onCampaignInvalidated("campaign-modal")
        SDKInstance.shared.onCampaignInvalidated("campaign-inline")

        #expect(SDKInstance.shared.controller.activePayload == nil)
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

    @Test("payload content decodes placementKey directly")
    func payloadContentDecodesPlacementKey() throws {
        let data = Data("""
        {
          "type": "inline",
          "placementKey": "hero_banner",
          "viewId": "hero_component",
          "args": { "name": "Ada" }
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(InAppPayloadContent.self, from: data)

        #expect(decoded.placementKey == "hero_banner")
        #expect(decoded.args == ["name": .string("Ada")])
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

        let payload = InAppPayload(
            id: "bridge-event",
            content: InAppPayloadContent(
                type: "dialog",
                args: ["campaign_key": .string("welcome_survey")]
            )
        )

        SDKInstance.shared.onCampaignTriggered(payload)

        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.id == "welcome_survey")
        #expect(SDKInstance.shared.surveyOrchestrator.state?.payload.content.args["campaign_key"] == .string("welcome_survey"))
    }
}

@Suite("NudgeActionParser")
struct NudgeActionParserTests {
    private func onClick(_ steps: [[String: Any]]) -> [String: Any] { ["steps": steps] }

    @Test("parses open url and deeplink by launch mode")
    func parsesUrls() {
        let actions = NudgeActionParser().parse(onClick([
            ["type": "Action.openUrl", "data": ["url": "https://x/y", "launchMode": "externalApplication"]],
            ["type": "Action.openUrl", "data": ["url": "app://path", "launchMode": "platformDefault"]],
        ]))
        #expect(actions == [.openUrl("https://x/y"), .openDeeplink("app://path")])
    }

    @Test("parses copy to clipboard from message")
    func parsesCopy() {
        let actions = NudgeActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": ["message": "PROMO50"]],
        ]))
        #expect(actions == [.copyToClipboard("PROMO50")])
    }

    @Test("parses share from message")
    func parsesShare() {
        let actions = NudgeActionParser().parse(onClick([
            ["type": "Action.share", "data": ["message": "check this out"]],
        ]))
        #expect(actions == [.share("check this out")])
    }

    @Test("text payload falls back to text then value keys")
    func textFallbacks() {
        let fromText = NudgeActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": ["text": "A"]],
        ]))
        let fromValue = NudgeActionParser().parse(onClick([
            ["type": "Action.share", "data": ["value": "B"]],
        ]))
        #expect(fromText == [.copyToClipboard("A")])
        #expect(fromValue == [.share("B")])
    }

    @Test("blank or missing text drops copy and share")
    func dropsBlank() {
        let actions = NudgeActionParser().parse(onClick([
            ["type": "Action.copyToClipBoard", "data": [:]],
            ["type": "Action.share", "data": ["message": ""]],
        ]))
        #expect(actions.isEmpty)
    }

    @Test("dismiss for hide bottom sheet and dismiss dialog")
    func parsesDismiss() {
        let actions = NudgeActionParser().parse(onClick([
            ["type": "Action.hideBottomSheet"],
            ["type": "Action.dismissDialog"],
        ]))
        #expect(actions == [.dismiss, .dismiss])
    }
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

    init(identifier: String) {
        self.identifier = identifier
    }

    func setup(delegate: DigiaCEPDelegate) {
        setupCount += 1
    }

    func registerPlaceholder(propertyID: String) -> Int? {
        placeholderRegistrations.append(propertyID)
        return placeholderIDToReturn
    }

    func deregisterPlaceholder(_ id: Int) {
        deregisteredPlaceholderIDs.append(id)
    }

    func notifyEvent(_ event: DigiaExperienceEvent, payload: InAppPayload) {}

    func healthCheck() -> DiagnosticReport {
        DiagnosticReport(isHealthy: true)
    }

    func teardown() {
        teardownCount += 1
    }
}
