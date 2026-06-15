import Foundation

// Ported from Android `CampaignStore.kt`. Accessed on the main actor (populated
// after fetch during SDKInstance.initialize), so no extra synchronization needed.
@MainActor
final class CampaignStore {
    private var campaigns: [String: CampaignModel] = [:]

    func populate(_ list: [CampaignModel]) {
        campaigns.removeAll()
        for campaign in list {
            campaigns[campaign.campaignKey] = campaign
        }
    }

    func find(_ campaignKey: String) -> CampaignModel? {
        campaigns[campaignKey]
    }

    var isEmpty: Bool {
        campaigns.isEmpty
    }

    func clear() {
        campaigns.removeAll()
    }
}
