/// The coarse, campaign-agnostic CEP protocol. The SDK forwards these to the
/// active ``DigiaCEPPlugin`` (via the emitter's CEP channel); the plugin maps
/// them onto the host CEP's own event model (CleverTap raised event, MoEngage
/// trigger).
///
/// This is a separate concern from Digia's rich, campaign-grouped analytics
/// events (``EngageAnalyticsEvent``): step/question/completed signals exist only
/// there and never reach the CEP.
public enum DigiaExperienceEvent: Sendable, Equatable {
    case impressed
    case clicked(elementID: String? = nil)
    case dismissed
}
