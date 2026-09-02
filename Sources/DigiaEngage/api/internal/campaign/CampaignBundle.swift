import Foundation

struct CampaignBundle {
    let rawCampaigns: [[String: Any]]
    let designTokens: DesignTokenCatalog
    let campaigns: [CampaignModel]

    static func create(
        rawCampaigns: [[String: Any]],
        designTokensJSON: [String: Any]?,
        devicePlatform: String? = nil,
        serverTimeMs: Int64? = nil,
        diagnostics: DiagnosticsReporter? = nil
    ) -> CampaignBundle {
        let catalog: DesignTokenCatalog
        do { catalog = try designTokensJSON.map(DesignTokenCatalog.fromJson) ?? .empty }
        catch {
            DigiaLog.warning("[CampaignBundle] invalid design tokens; using literals only: \(error.localizedDescription)")
            catalog = .empty
        }
        let timeAnchor = TrustedTimeAnchor.capture(serverTimeMs)
        let campaigns = rawCampaigns.enumerated().compactMap { index, json in
            if let campaign = CampaignModel.fromJson(
                json,
                designTokens: catalog,
                devicePlatform: devicePlatform,
                timeAnchor: timeAnchor,
                diagnostics: diagnostics
            ) { return campaign }
            DigiaLog.warning("[CampaignBundle] skipping malformed campaign at index \(index)")
            return nil
        }
        return CampaignBundle(
            rawCampaigns: rawCampaigns,
            designTokens: catalog,
            campaigns: campaigns
        )
    }
}
