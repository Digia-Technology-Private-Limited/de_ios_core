import Foundation

@MainActor
final class CampaignStore {
    private var campaigns: [String: CampaignModel] = [:]

    func populate(_ campaigns: [CampaignModel]) {
        self.campaigns = Dictionary(uniqueKeysWithValues: campaigns.map { ($0.campaignKey, $0) })
    }

    func find(_ campaignKey: String) -> CampaignModel? {
        campaigns[campaignKey]
    }

    var isEmpty: Bool { campaigns.isEmpty }
}
