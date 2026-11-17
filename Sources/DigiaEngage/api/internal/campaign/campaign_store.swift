import Foundation

// Ported from Android `CampaignStore.kt`. Accessed on the main actor (populated
// after fetch during SDKInstance.initialize), so no extra synchronization needed.
@MainActor
final class CampaignStore {
    private var campaigns: [String: CampaignModel] = [:]
    private var index = TriggerIndex([])

    func populate(_ list: [CampaignModel]) {
        campaigns.removeAll()
        var ordered: [String] = []
        for campaign in list {
            if campaigns.updateValue(campaign, forKey: campaign.campaignKey) == nil {
                ordered.append(campaign.campaignKey)
            }
        }
        // Catalog order, one entry per key: a duplicate key keeps its first position.
        index = TriggerIndex(ordered.compactMap { campaigns[$0] })
    }

    /// The Digia-owned campaigns whose rule listens for `signal`, in catalog order.
    func listeningTo(_ signal: RuleSignal) -> [CampaignModel] {
        index.listeningTo(signal)
    }

    /// Every cached campaign, in no particular order.
    var all: [CampaignModel] { Array(campaigns.values) }

    func find(_ campaignKey: String) -> CampaignModel? {
        campaigns[campaignKey]
    }

    var keys: [String] {
        campaigns.keys.sorted()
    }

    var debugSummary: String {
        campaigns.values
            .sorted { $0.campaignKey < $1.campaignKey }
            .map { "\($0.campaignKey):\($0.campaignType)" }
            .joined(separator: ", ")
    }

    var isEmpty: Bool {
        campaigns.isEmpty
    }

    func clear() {
        campaigns.removeAll()
        index = TriggerIndex([])
    }
}
