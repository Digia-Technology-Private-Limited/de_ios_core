import Foundation

enum GuideRenderer: Equatable {
    case native
    case reactNative

    init(wireValue: String?) {
        self = wireValue == "native" ? .native : .reactNative
    }
}

struct CampaignBundle {
    let rawCampaigns: [[String: Any]]
    let designTokens: DesignTokenCatalog
    let campaigns: [CampaignModel]
    let guideRenderer: GuideRenderer

    static func create(
        rawCampaigns: [[String: Any]],
        designTokensJSON: [String: Any]?,
        devicePlatform: String? = nil,
        guideRenderer: GuideRenderer = .reactNative
    ) -> CampaignBundle {
        let catalog: DesignTokenCatalog
        do { catalog = try designTokensJSON.map(DesignTokenCatalog.fromJson) ?? .empty }
        catch {
            DigiaLog.warning("[CampaignBundle] invalid design tokens; using literals only: \(error.localizedDescription)")
            catalog = .empty
        }
        let campaigns = rawCampaigns.enumerated().compactMap { index, json in
            if let campaign = CampaignModel.fromJson(json, designTokens: catalog, devicePlatform: devicePlatform) { return campaign }
            DigiaLog.warning("[CampaignBundle] skipping malformed campaign at index \(index)")
            return nil
        }
        return CampaignBundle(
            rawCampaigns: rawCampaigns,
            designTokens: catalog,
            campaigns: campaigns,
            guideRenderer: guideRenderer
        )
    }
}
