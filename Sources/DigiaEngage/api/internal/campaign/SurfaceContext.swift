import Foundation

/// What every surface's reporter reads from the SDK: the emitter, the dwell
/// clock, the current screen and the frequency counts.
///
/// Each is read when used, so a reporter can be built before the SDK is
/// initialized. The SDK itself stays reachable for the lookups only it can do
/// (live-test bookkeeping, the campaign store, logging) — those stay behind
/// `sdk` rather than growing this interface.
///
/// Two behaviors are preserved: live tests never consume frequency budget, and
/// `recordShow` / `recordCompleted` take the store's frequency policy.
@MainActor
final class SurfaceContext {
    init(sdk: SDKInstance) { self.sdk = sdk }

    /// The SDK. Reporters reach through it for store, live-test and logging
    /// lookups; the hot paths above stay direct.
    unowned let sdk: SDKInstance

    var events: EngageEventEmitter { sdk.events }
    var dwell: DwellTracker { sdk.dwellTracker }
    var currentScreen: String? { sdk.currentScreenForAnchorless }
    var services: SDKServices? { sdk.services }

    /// The campaign was seen: counts one show of `campaignKey`, starts its
    /// dwell clock and reports `viewed` to the CEP and to Digia.
    func impressed(
        _ payload: CEPTriggerPayload,
        campaignKey: String,
        viewed: EngageAnalyticsEvent
    ) {
        dwell.markViewed(payload.cepCampaignId)
        recordShow(campaignKey: campaignKey, cepCampaignId: payload.cepCampaignId)
        events.toBoth(.impressed, viewed, payload: payload)
    }

    /// Records one show of `campaignKey` (on "Digia Experience Viewed").
    /// No-op for live tests and capless campaigns.
    func recordShow(campaignKey: String, cepCampaignId: String) {
        guard !isLiveTestCepId(cepCampaignId),
            let services,
            let campaign = sdk.campaignStore.find(campaignKey)
        else { return }
        services.frequencyManager.recordShow(campaignKey, campaign.frequency)
    }

    /// Applies the permanent stop for `campaignKey` (on "Digia Experience
    /// Completed") when its policy opted into `stopOn: experienceCompleted`.
    /// No-op for live tests and capless campaigns.
    func recordCompleted(campaignKey: String, cepCampaignId: String) {
        guard !isLiveTestCepId(cepCampaignId),
            let services,
            let campaign = sdk.campaignStore.find(campaignKey)
        else { return }
        services.frequencyManager.recordCompleted(campaignKey, campaign.frequency)
    }
}
