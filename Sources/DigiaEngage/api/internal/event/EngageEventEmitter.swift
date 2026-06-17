import Foundation

/// The SDK's single entry point for emitting events.
///
/// Facade over the two delivery channels, which carry deliberately different
/// event models: the CEP plugin gets the coarse ``DigiaExperienceEvent`` protocol
/// via ``toCep(_:payload:)``; Digia analytics gets the rich, campaign-grouped
/// ``EngageAnalyticsEvent`` via ``toDigia(_:payload:)``. ``toBoth(_:_:payload:)``
/// fires a dual signal (e.g. a nudge impression). Also owns the first-render
/// impression dedup, an emission concern rather than widget state. Ported from
/// Android `internal/event/EngageEventEmitter.kt`.
@MainActor
final class EngageEventEmitter {
    private let cep: CepPluginSink
    private let digia: DigiaAnalyticsSink

    /// `cepCampaignId`s that have already fired a Digia first-render impression.
    private var digiaImpressed: Set<String> = []

    init(cep: CepPluginSink, digia: DigiaAnalyticsSink) {
        self.cep = cep
        self.digia = digia
    }

    /// Coarse signal to the CEP plugin only.
    func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        cep.deliver(event, payload: payload)
    }

    /// Rich analytics signal to Digia only.
    func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        digia.deliver(event, payload: payload)
    }

    /// Fires a coarse CEP signal and its rich Digia counterpart together.
    func toBoth(_ cepEvent: DigiaExperienceEvent, _ digiaEvent: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        toCep(cepEvent, payload: payload)
        toDigia(digiaEvent, payload: payload)
    }

    /// Records `event` (a campaign "Viewed") to Digia the first time its campaign
    /// renders, deduped by `cepCampaignId`. CEP is impressed separately and
    /// instantly at route time.
    func digiaImpressionOnce(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
        guard digiaImpressed.insert(payload.cepCampaignId).inserted else { return }
        toDigia(event, payload: payload)
    }

    /// Forgets the impression mark so a later re-trigger impresses afresh.
    func resetImpression(_ cepCampaignId: String) {
        digiaImpressed.remove(cepCampaignId)
    }

    /// Forgets every impression mark.
    func clearImpressions() {
        digiaImpressed.removeAll()
    }
}
