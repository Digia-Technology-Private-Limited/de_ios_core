private let log = DigiaLogger()

/// One campaign asking to be shown, plus the driver that asked.
///
/// The gates read this and nothing else about where the campaign came from, so
/// they never learn whether a CEP, a live test, or Digia's rule engine
/// delivered it — only the driver's ``SourcePolicy`` says how they differ.
///
/// platform note: the Dart twin rebuilds the payload with `type` stamped into
/// the metadata. Swift's payload carries a core-minted `presentationId` that a
/// rebuild would lose, so the trigger travels unchanged.
struct CampaignRequest {
    let driver: CampaignDriver
    let campaign: CampaignModel
    let payload: CEPTriggerPayload

    /// The drop for a campaign whose own config cannot be rendered, with `cause`
    /// carrying the symbolic reason. Logs it and reports it to the driver first.
    @MainActor
    func invalidConfig(_ detail: String, cause: String) -> RoutingVerdict {
        log.e("Dropped — \(detail)", campaign: campaign.campaignKey)
        driver.policy.onDropped(DropReason.invalidConfig, detail)
        return .dropped(reason: .invalidConfig, detail: detail, extras: ["cause": cause])
    }
}

extension CampaignModel {
    /// The surface row this campaign arrives on; nil for a config this SDK
    /// cannot render.
    var surfaceArrival: SurfaceKind? {
        switch config {
        case .inline(let cfg): return .inline(slot: cfg.slotKey)
        case .banner(let cfg): return .inline(slot: cfg.slotKey)
        case .inlineCanvas(let cfg): return .inline(slot: cfg.slotKey)
        case .story(let cfg): return .inline(slot: cfg.slotKey)
        case .nudge: return .nudge
        case .survey: return .survey
        case .guide: return .guide
        case .floater, .floaterStory: return .floaterCollapsed
        case .unsupported: return nil
        }
    }
}
