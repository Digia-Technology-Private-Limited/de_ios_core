import SwiftUI
import Combine

@MainActor
final class InlineCampaignController: ObservableObject {
    @Published private var campaigns: [String: CEPTriggerPayload] = [:]
    @Published private var carouselConfigs: [String: InlineCarouselConfig] = [:]
    @Published private var bannerConfigs: [String: InlineBannerConfig] = [:]
    @Published private var storyConfigs: [String: InlineStoryConfig] = [:]
    @Published private var canvasConfigs: [String: InlineCanvasConfig] = [:]
    var onCampaignRemoved: ((CEPTriggerPayload) -> Void)?

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

    func getCanvasConfig(_ placementKey: String) -> InlineCanvasConfig? {
        canvasConfigs[placementKey]
    }

    func setCampaign(_ placementKey: String, payload: CEPTriggerPayload) {
        let previous = campaigns[placementKey]
        var next = campaigns
        next[placementKey] = payload
        campaigns = next
        if let previous, previous.cepCampaignId != payload.cepCampaignId {
            notifyRemovedCampaigns([previous])
        }
    }

    // Each setter clears every other kind for the slot: one slot holds one
    // campaign, and `DigiaSlot` resolves the kinds in a fixed order. Carousel and
    // story used not to clear each other, and since carousel is resolved first, a
    // story routed into a slot that had held a carousel never appeared — the
    // stale carousel kept winning.
    func setCarouselConfig(_ placementKey: String, config: InlineCarouselConfig) {
        bannerConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
        canvasConfigs.removeValue(forKey: placementKey)
        var next = carouselConfigs
        next[placementKey] = config
        carouselConfigs = next
    }

    func setStoryConfig(_ placementKey: String, config: InlineStoryConfig) {
        bannerConfigs.removeValue(forKey: placementKey)
        carouselConfigs.removeValue(forKey: placementKey)
        canvasConfigs.removeValue(forKey: placementKey)
        var next = storyConfigs
        next[placementKey] = config
        storyConfigs = next
    }

    func setBannerConfig(_ placementKey: String, config: InlineBannerConfig) {
        carouselConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
        canvasConfigs.removeValue(forKey: placementKey)
        var next = bannerConfigs
        next[placementKey] = config
        bannerConfigs = next
    }

    func setCanvasConfig(_ placementKey: String, config: InlineCanvasConfig) {
        carouselConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
        bannerConfigs.removeValue(forKey: placementKey)
        var next = canvasConfigs
        next[placementKey] = config
        canvasConfigs = next
    }

    func removeCampaign(_ campaignID: String) {
        let removedKeys =
            campaigns
            .filter { $0.key == campaignID || $0.value.cepCampaignId == campaignID }
            .map(\.key)
        let removedPayloads = removedKeys.compactMap { campaigns[$0] }
        campaigns = campaigns.filter { placementKey, payload in
            placementKey != campaignID && payload.cepCampaignId != campaignID
        }
        for key in removedKeys {
            carouselConfigs.removeValue(forKey: key)
            bannerConfigs.removeValue(forKey: key)
            storyConfigs.removeValue(forKey: key)
            canvasConfigs.removeValue(forKey: key)
        }
        notifyRemovedCampaigns(removedPayloads)
    }

    func dismissCampaign(_ placementKey: String) {
        let removed = campaigns.removeValue(forKey: placementKey)
        carouselConfigs.removeValue(forKey: placementKey)
        bannerConfigs.removeValue(forKey: placementKey)
        storyConfigs.removeValue(forKey: placementKey)
        canvasConfigs.removeValue(forKey: placementKey)
        if let removed { notifyRemovedCampaigns([removed]) }
    }

    func clear() {
        let removed = Array(campaigns.values)
        campaigns.removeAll()
        carouselConfigs.removeAll()
        bannerConfigs.removeAll()
        storyConfigs.removeAll()
        canvasConfigs.removeAll()
        notifyRemovedCampaigns(removed)
    }

    private func notifyRemovedCampaigns(_ removed: [CEPTriggerPayload]) {
        var remainingIds = Set(campaigns.values.map(\.cepCampaignId))
        for payload in removed where remainingIds.insert(payload.cepCampaignId).inserted {
            onCampaignRemoved?(payload)
        }
    }
}
