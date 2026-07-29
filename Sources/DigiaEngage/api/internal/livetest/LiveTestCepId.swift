import Foundation

/// Marks a synthetic `CEPTriggerPayload.cepCampaignId` built for a live test, so
/// `EngageEventEmitter` can suppress real CEP/analytics delivery for it without
/// importing the rest of this feature.
private let liveTestCepIdPrefix = "digia_live_test:"

func liveTestCepId(_ testInvocationId: String) -> String {
    "\(liveTestCepIdPrefix)\(testInvocationId)"
}

func isLiveTestCepId(_ cepCampaignId: String) -> Bool {
    cepCampaignId.hasPrefix(liveTestCepIdPrefix)
}
