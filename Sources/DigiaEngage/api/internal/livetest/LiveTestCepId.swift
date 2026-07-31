import Foundation

private let liveTestCepIdPrefix = "digia_live_test:"

func liveTestCepId(_ testInvocationId: String) -> String {
    "\(liveTestCepIdPrefix)\(testInvocationId)"
}

func isLiveTestCepId(_ cepCampaignId: String) -> Bool {
    cepCampaignId.hasPrefix(liveTestCepIdPrefix)
}
