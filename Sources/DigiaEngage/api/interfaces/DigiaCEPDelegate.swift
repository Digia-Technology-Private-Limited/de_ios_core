@MainActor
public protocol DigiaCEPDelegate: AnyObject {
    func onCampaignTriggered(_ payload: CEPTriggerPayload)
    func onCampaignInvalidated(_ campaignID: String)
}
