import Foundation
@testable import DigiaEngage
import Testing

@MainActor
@Suite("Inline banner", .serialized)
struct InlineBannerTests {
    @Test("parses the canonical banner config")
    func parsesCanonicalConfig() throws {
        let config = try #require(InlineBannerConfig.fromJson(Self.configJson))

        #expect(config.slotKey == "home_hero")
        #expect(config.image.url == "https://example.com/{{ image }}.png")
        #expect(config.image.placeholder?.blurHash == "LKO2?U%2Tw=w]~RBVZRi};RPxuwH")
        #expect(config.image.boxFit == .contain)
        #expect(config.image.aspectRatio == 1.5)
        #expect(config.image.height == 240)
        #expect(config.image.cornerRadius == 18)
        #expect(config.margin == InlineBannerMargin(top: 1, right: 2, bottom: 3, left: 4))
        #expect(config.actions == [.openDeeplink("medihub://{{ route }}"), .share("{{ message }}")])
        #expect(config.variableSchemas == [
            VariableSchema(name: "route", type: "string", fallbackValue: "cart")
        ])
    }

    @Test("rejects missing required fields")
    func rejectsMissingRequiredFields() {
        var missingSlot = Self.configJson
        missingSlot["slotKey"] = ""
        #expect(InlineBannerConfig.fromJson(missingSlot) == nil)

        var missingImage = Self.configJson
        missingImage["image"] = ["url": ""]
        #expect(InlineBannerConfig.fromJson(missingImage) == nil)
    }

    @Test("filters unsupported actions")
    func filtersUnsupportedActions() throws {
        var json = Self.configJson
        json["onClick"] = ["steps": [
            ["type": "Action.hideBottomSheet"],
            ["type": "Action.requestReview"],
            ["type": "Action.copyToClipBoard", "data": ["text": "code"]],
        ]]

        let config = try #require(InlineBannerConfig.fromJson(json))
        #expect(config.actions == [.copyToClipboard("code")])
    }

    @Test("campaign parsing and routing use the banner subtype")
    func parsesAndRoutesBannerCampaign() throws {
        SDKInstance.shared.resetForTesting()
        let campaign = try #require(CampaignModel.fromJson([
            "id": "banner-id",
            "campaignKey": "banner-campaign",
            "campaignType": "inline",
            "templateConfig": Self.configJson.merging(["templateType": "banner"]) { _, new in new },
        ]))
        SDKInstance.shared.campaignStore.populate([campaign])

        let accepted = SDKInstance.shared.onCampaignTriggered(CEPTriggerPayload(
            cepCampaignId: "cep-banner",
            campaignKey: "banner-campaign",
            cepMetadata: [:]
        ))

        #expect(accepted)
        #expect(campaign.bannerConfig?.slotKey == "home_hero")
        #expect(SDKInstance.shared.inlineController.getBannerConfig("home_hero") != nil)
        #expect(SDKInstance.shared.inlineController.getCampaign("home_hero")?.cepCampaignId == "cep-banner")
    }

    @Test("banner analytics use canonical properties")
    func usesCanonicalAnalyticsProperties() {
        #expect(BannerEvent.Viewed(slotKey: "home_hero", screenName: "home").properties as NSDictionary == [
            "display_style": "banner",
            "slot_key": "home_hero",
            "screen_name": "home",
        ] as NSDictionary)
        #expect(BannerEvent.Clicked(actionType: "deeplink", actionUrl: "medihub://cart").properties as NSDictionary == [
            "element_id": "banner",
            "action_type": "deeplink",
            "action_url": "medihub://cart",
        ] as NSDictionary)
    }

    private static let configJson: [String: Any] = [
        "slotKey": "home_hero",
        "image": [
            "url": "https://example.com/{{ image }}.png",
            "placeholder": [
                "type": "blurhash",
                "blurHash": "LKO2?U%2Tw=w]~RBVZRi};RPxuwH",
            ],
            "boxFit": "contain",
            "aspectRatio": 1.5,
            "height": 240,
            "cornerRadius": 18,
        ],
        "layout": [
            "margin": ["top": 1, "right": 2, "bottom": 3, "left": 4]
        ],
        "onClick": ["steps": [
            [
                "type": "Action.openUrl",
                "data": ["url": "medihub://{{ route }}", "launchMode": "platformDefault"],
            ],
            ["type": "Action.share", "data": ["text": "{{ message }}"]],
        ]],
        "variables": [
            ["name": "route", "type": "string", "fallbackValue": "cart"]
        ],
    ]
}
