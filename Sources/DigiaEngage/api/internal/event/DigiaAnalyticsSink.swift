import Foundation

/// Delivers rich ``EngageAnalyticsEvent``s to Digia's first-party analytics backend.
///
/// Resolves the campaign from the store by `campaignKey` for attribution context
/// (campaign id/type live on the `CampaignModel`, not the trigger payload), then
/// hands the event to ``AnalyticsService``, which hoists
/// ``EngageAnalyticsEvent/columns`` to top level and nests
/// ``EngageAnalyticsEvent/properties``. Ported from Android
/// `internal/event/DigiaAnalyticsSink.kt`.
@MainActor
final class DigiaAnalyticsSink {
    private let getAnalyticsService: () -> AnalyticsService?
    private let getCampaign: (String) -> CampaignModel?

    init(
        getAnalyticsService: @escaping () -> AnalyticsService?,
        getCampaign: @escaping (String) -> CampaignModel?
    ) {
        self.getAnalyticsService = getAnalyticsService
        self.getCampaign = getCampaign
    }

    func deliver(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        guard let svc = getAnalyticsService() else { return }
        let campaign = getCampaign(payload.campaignKey)
        svc.capture(event, payload: payload, campaignId: campaign?.id, campaignType: campaign?.campaignType)
    }
}
