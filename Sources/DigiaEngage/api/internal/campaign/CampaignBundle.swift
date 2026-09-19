import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

struct CampaignBundle {
    let rawCampaigns: [[String: Any]]
    let designTokens: DesignTokenCatalog
    let timeAnchor: TrustedTimeAnchor?
    let campaigns: [CampaignModel]

    static func create(
        rawCampaigns: [[String: Any]],
        designTokensJSON: [String: Any]?,
        devicePlatform: String? = nil,
        serverTimeMs: Int64? = nil
    ) -> CampaignBundle {
        let catalog: DesignTokenCatalog
        do { catalog = try designTokensJSON.map(DesignTokenCatalog.fromJson) ?? .empty }
        catch {
            log.e(
                "Design tokens unreadable — falling back to literal values",
                error: error.localizedDescription,
                stage: .parse,
                reason: TimelineReason.designTokensUnreadable
            )
            catalog = .empty
        }
        let timeAnchor = TrustedTimeAnchor.capture(serverTimeMs)
        let campaigns = rawCampaigns.enumerated().compactMap { index, json in
            if let campaign = CampaignModel.fromJson(
                json,
                designTokens: catalog,
                devicePlatform: devicePlatform,
                timeAnchor: timeAnchor
            ) { return campaign }
            log.e(
                "Campaign skipped — could not be read (index=\(index))",
                stage: .parse,
                reason: TimelineReason.malformedCampaignSkipped
            )
            return nil
        }
        return CampaignBundle(
            rawCampaigns: rawCampaigns,
            designTokens: catalog,
            timeAnchor: timeAnchor,
            campaigns: campaigns
        )
    }
}
