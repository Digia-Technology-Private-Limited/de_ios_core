import SwiftUI

@MainActor
final class InlineCampaignController: ObservableObject {
    @Published private var campaigns: [String: InAppPayload] = [:]
    @Published private var carouselConfigs: [String: InlineCarouselConfig] = [:]
    var onEvent: ((DigiaExperienceEvent, InAppPayload) -> Void)?

    func getCampaign(_ placementKey: String) -> InAppPayload? {
        campaigns[placementKey]
    }

    func getCarouselConfig(_ placementKey: String) -> InlineCarouselConfig? {
        carouselConfigs[placementKey]
    }

    func setCampaign(_ placementKey: String, payload: InAppPayload) {
        var next = campaigns
        next[placementKey] = payload
        campaigns = next
    }

    func setCarouselConfig(_ placementKey: String, config: InlineCarouselConfig) {
        var next = carouselConfigs
        next[placementKey] = config
        carouselConfigs = next
    }

    func removeCampaign(_ campaignID: String) {
        let removedKeys =
            campaigns
            .filter { $0.key == campaignID || $0.value.id == campaignID }
            .map(\.key)
        campaigns = campaigns.filter { placementKey, payload in
            placementKey != campaignID && payload.id != campaignID
        }
        for key in removedKeys {
            carouselConfigs.removeValue(forKey: key)
        }
    }

    func dismissCampaign(_ placementKey: String) {
        campaigns.removeValue(forKey: placementKey)
        carouselConfigs.removeValue(forKey: placementKey)
    }

    func clear() {
        campaigns.removeAll()
        carouselConfigs.removeAll()
    }
}
