import Foundation

/// The translation contract between a CEP plugin and Digia's rendering engine.
///
/// Mirrors `CEPTriggerPayload` in Android / Flutter. Plugin authors map their
/// CEP's native campaign callback into this struct; Digia core never imports
/// CleverTap, MoEngage, or WebEngage types.
///
/// It is the single payload the SDK carries end-to-end: the CEP plugin / bridge
/// builds it at the boundary, the delegate routes it by `campaignKey` through the
/// campaign store, and it flows into ``DigiaCEPPlugin/notifyEvent(_:payload:)``
/// and the analytics pipeline.
public struct CEPTriggerPayload: Sendable, Equatable {
    /// The CEP's own identifier for this campaign instance. Opaque to Digia core.
    public let cepCampaignId: String

    /// The coupling key that links this CEP campaign to a Digia campaign config.
    public let campaignKey: String

    /// Any additional metadata the CEP passes through (e.g. template name, UTM
    /// params, segment label). Core does not interpret these — forwarded as-is
    /// in lifecycle events.
    public let cepMetadata: [String: String]

    /// Optional runtime variables to interpolate into the campaign config, e.g.
    /// `["user_name": "Priya", "offer_value": "20%"]`. Keys must match variable
    /// placeholders declared in the Digia dashboard.
    public let variables: [String: String]?

    public init(
        cepCampaignId: String,
        campaignKey: String,
        cepMetadata: [String: String] = [:],
        variables: [String: String]? = nil
    ) {
        self.cepCampaignId = cepCampaignId
        self.campaignKey = campaignKey
        self.cepMetadata = cepMetadata
        self.variables = variables
    }
}
