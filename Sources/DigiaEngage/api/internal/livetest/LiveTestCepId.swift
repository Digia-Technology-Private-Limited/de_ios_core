import Foundation

private let liveTestCepIdPrefix = "digia_live_test:"

func liveTestCepId(_ testInvocationId: String) -> String {
    "\(liveTestCepIdPrefix)\(testInvocationId)"
}

func isLiveTestCepId(_ cepCampaignId: String) -> Bool {
    cepCampaignId.hasPrefix(liveTestCepIdPrefix)
}

/// The inverse of ``liveTestCepId``: the `testInvocationId` inside a synthetic
/// id, or nil when `cepCampaignId` did not come from a live test.
///
/// This is what lets a live-only event need no bookkeeping of its own: a
/// surface still holds the payload long after the invocation's
/// `LiveTestContext` has been cleaned up on its terminal ACK, and the id it
/// needs is already encoded in the payload it is holding.
func testInvocationIdOf(_ cepCampaignId: String) -> String? {
    guard isLiveTestCepId(cepCampaignId) else { return nil }
    return String(cepCampaignId.dropFirst(liveTestCepIdPrefix.count))
}
