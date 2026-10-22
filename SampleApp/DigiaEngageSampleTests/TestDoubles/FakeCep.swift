import Foundation

@testable import DigiaEngage

/// A CEP integration reduced to what it does in production: hold the host and hand it triggers.
@MainActor
final class FakeCep: DigiaCEPPlugin {
    private(set) var host: DigiaCEPHost?

    var id: String { "fixture-tests" }

    func attach(host: DigiaCEPHost) { self.host = host }
    func detach() { host = nil }

    /// What the CEP does when its campaign fires.
    @discardableResult
    func deliver(_ campaignKey: String, variables: [String: String]? = nil) -> CampaignPresentation? {
        host?.deliver(CEPTriggerPayload(
            cepCampaignId: "cep-\(campaignKey)",
            campaignKey: campaignKey,
            cepMetadata: [:],
            variables: variables
        ))
    }
}
