import Foundation

struct CampaignModel {
    let id: String
    let campaignKey: String
    let campaignType: String
    let inlineConfig: InlineCarouselConfig?

    static func fromJson(_ json: [String: Any]) -> CampaignModel? {
        let id = ((json["id"] as? String) ?? (json["_id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        guard let campaignKey = (json["campaign_key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !campaignKey.isEmpty else { return nil }

        guard let campaignType = (json["campaign_type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !campaignType.isEmpty else { return nil }

        let inlineConfig: InlineCarouselConfig? = campaignType == "inline"
            ? (json["template_config"] as? [String: Any]).flatMap(InlineCarouselConfig.fromJson)
            : nil

        return CampaignModel(
            id: id,
            campaignKey: campaignKey,
            campaignType: campaignType,
            inlineConfig: inlineConfig
        )
    }
}
