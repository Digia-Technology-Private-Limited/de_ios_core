@MainActor
public protocol DigiaCEPDelegate: AnyObject {
    /// Called synchronously (on the calling thread, which must be the main thread) when a CEP
    /// plugin has a campaign ready to trigger. Returns `true` if Digia accepted the campaign for
    /// rendering, `false` if it was dropped (unknown key, frequency capped, SDK not ready, etc).
    ///
    /// CEP plugins that hold a rendering slot for the campaign (e.g. a single in-app "context")
    /// MUST release that slot when this returns `false`, or subsequent campaigns may queue or
    /// stall indefinitely behind the un-released one.
    func onCampaignTriggered(_ payload: CEPTriggerPayload) -> Bool

    /// Called when a previously delivered campaign is no longer valid. Digia dismisses the
    /// active nudge or inline payload with a matching id.
    func onCampaignInvalidated(_ campaignID: String)
}
