import Foundation

/// Delivers rich ``EngageAnalyticsEvent``s to Digia's first-party analytics backend.
///
/// Resolves the campaign from the store by `campaignKey` for attribution context
/// (campaign id/type live on the `CampaignModel`, not the trigger payload), then
/// and the delivery's `presentation_id`, then hands the event to
/// ``AnalyticsService``, which nests
/// ``EngageAnalyticsEvent/properties`` under the wire `properties` key.
/// Ported from Android `internal/event/DigiaAnalyticsSink.kt`.
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
        svc.capture(
            event,
            payload: payload,
            campaignId: campaign?.id,
            campaignType: campaign?.campaignType,
            // Read straight off the payload: the coordinator stamped it there at
            // `deliver()`, and the payload is what every surface hands back.
            presentationId: payload.presentationId
        )
    }
}
