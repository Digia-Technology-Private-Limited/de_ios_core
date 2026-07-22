import SwiftUI
import Combine

@MainActor
final class InlineCampaignController: ObservableObject {
    @Published private var campaigns: [String: CEPTriggerPayload] = [:]
    @Published private var carouselConfigs: [String: InlineCarouselConfig] = [:]
    @Published private var bannerConfigs: [String: InlineBannerConfig] = [:]
    @Published private var storyConfigs: [String: InlineStoryConfig] = [:]

    func getCampaign(_ placementKey: String) -> CEPTriggerPayload? {
        campaigns[placementKey]
    }

    func getCarouselConfig(_ placementKey: String) -> InlineCarouselConfig? {
        carouselConfigs[placementKey]
    }

    func getStoryConfig(_ placementKey: String) -> InlineStoryConfig? {
        storyConfigs[placementKey]
    }

    func getBannerConfig(_ placementKey: String) -> InlineBannerConfig? {
        bannerConfigs[placementKey]
    }

    func setCampaign(_ placementKey: String, payload: CEPTriggerPayload) {
        var next = campaigns
        next[placementKey] = payload
        campaigns = next
    }

    func setCarouselConfig(_ placementKey: String, config: InlineCarouselConfig) {
        bannerConfigs.removeValue(forKey: placementKey)
        var next = carouselConfigs
        next[placementKey] = config
        carouselConfigs = next
    }

    func setStoryConfig(_ placementKey: String, config: InlineStoryConfig) {
        bannerConfigs.removeValue(forKey: placementKey)
        var next = storyConfigs
        next[placementKey] = config
        storyConfigs = next
    }

    func setBannerConfig(_ placementKey: String, config: InlineBannerConfig) {
        carouselConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
        var next = bannerConfigs
        next[placementKey] = config
        bannerConfigs = next
    }

    func removeCampaign(_ campaignID: String) {
        let removedKeys =
            campaigns
            .filter { $0.key == campaignID || $0.value.cepCampaignId == campaignID }
            .map(\.key)
        campaigns = campaigns.filter { placementKey, payload in
            placementKey != campaignID && payload.cepCampaignId != campaignID
        }
        for key in removedKeys {
            carouselConfigs.removeValue(forKey: key)
            bannerConfigs.removeValue(forKey: key)
            storyConfigs.removeValue(forKey: key)
        }
    }

    func dismissCampaign(_ placementKey: String) {
        campaigns.removeValue(forKey: placementKey)
        carouselConfigs.removeValue(forKey: placementKey)
        bannerConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
    }

    func clear() {
        campaigns.removeAll()
        carouselConfigs.removeAll()
        bannerConfigs.removeAll()
        storyConfigs.removeAll()
    }
}
