import Foundation
import os

/// Unified-logging channel for event emissions. Visible to Console.app and
/// `log stream` (unlike `print`, which only reaches stdout). Filter with:
/// `log stream --predicate 'subsystem == "tech.digia.engage"'` or
/// `... 'eventMessage CONTAINS "DigiaEvent"'`.
private let eventLog = os.Logger(subsystem: "tech.digia.engage", category: "DigiaEvent")

/// The SDK's single entry point for emitting events, and the one place every
/// emission is logged.
///
/// Facade over the two delivery channels, which carry deliberately different
/// event models: the CEP plugin gets the coarse ``DigiaExperienceEvent`` protocol
/// via ``toCep(_:payload:)``; Digia analytics gets the rich, campaign-grouped
/// ``EngageAnalyticsEvent`` via ``toDigia(_:payload:)``. ``toBoth(_:_:payload:)``
/// fires a dual signal (e.g. a nudge impression). Also owns the first-render
/// impression dedup, an emission concern rather than widget state. Ported from
/// Android `internal/event/EngageEventEmitter.kt`.
///
/// A live test's synthetic payload (`isLiveTestCepId`) never reaches a real CEP
/// plugin or Digia analytics — a test on a QA device must not pollute
/// production campaign metrics. `DigiaExperienceEvent.impressed` is instead
/// repurposed as the "shown" signal live testing waits for, via
/// `onLiveTestShown` — nudge/survey both already fire it once their render is
/// actually confirmed (`reportNudgeImpression`/`reportSurveyStarted`).
@MainActor
final class EngageEventEmitter {
    private let cep: CepPluginSink
    private let digia: DigiaAnalyticsSink
    private let onLiveTestShown: ((String) -> Void)?

    /// `cepCampaignId`s that have already fired a Digia first-render impression.
    private var digiaImpressed: Set<String> = []

    /// `cepCampaignId`s that have already fired a Digia first-engagement click.
    private var digiaClicked: Set<String> = []

    init(cep: CepPluginSink, digia: DigiaAnalyticsSink, onLiveTestShown: ((String) -> Void)? = nil) {
        self.cep = cep
        self.digia = digia
        self.onLiveTestShown = onLiveTestShown
    }

    /// Coarse signal to the CEP plugin only.
    func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        if isLiveTestCepId(payload.cepCampaignId) {
            if case .impressed = event { onLiveTestShown?(payload.cepCampaignId) }
            return
        }
        eventLog.info(
            "[DigiaEvent] Event fired → CEP: \(String(describing: event), privacy: .public) | campaignKey=\(payload.campaignKey, privacy: .public) cepCampaignId=\(payload.cepCampaignId, privacy: .public)"
        )
        cep.deliver(event, payload: payload)
    }

    /// Rich analytics signal to Digia only. Suppressed for a live test payload — see `toCep`.
    func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        if isLiveTestCepId(payload.cepCampaignId) { return }
        eventLog.info(
            "[DigiaEvent] Event fired → DIGIA: '\(event.eventName, privacy: .public)' (\(String(describing: type(of: event)), privacy: .public)) | campaignKey=\(payload.campaignKey, privacy: .public) cepCampaignId=\(payload.cepCampaignId, privacy: .public) properties=\(String(describing: event.properties), privacy: .public)"
        )
        digia.deliver(event, payload: payload)
    }

    /// Fires a coarse CEP signal and its rich Digia counterpart together.
    func toBoth(_ cepEvent: DigiaExperienceEvent, _ digiaEvent: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        toCep(cepEvent, payload: payload)
        toDigia(digiaEvent, payload: payload)
    }

    /// Records `event` (a campaign "Viewed") to Digia the first time its campaign
    /// renders, deduped by `cepCampaignId`. CEP is impressed separately and
    /// instantly at route time. (Inline-only in practice today — nudge/survey's
    /// "shown" signal is `toCep`'s `.impressed` branch above instead — but kept
    /// live-test-aware for parity with the sibling ports.)
    func digiaImpressionOnce(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
        guard digiaImpressed.insert(payload.cepCampaignId).inserted else { return }
        if isLiveTestCepId(payload.cepCampaignId) {
            onLiveTestShown?(payload.cepCampaignId)
            return
        }
        toDigia(event, payload: payload)
    }

    /// Records `event` (an experience-level "Clicked") to Digia the first time the
    /// user engages with this campaign, deduped by `cepCampaignId`. Used for inline
    /// widgets where the first item tap is the campaign's engagement signal.
    func digiaExperienceClickedOnce(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
        guard digiaClicked.insert(payload.cepCampaignId).inserted else { return }
        toDigia(event, payload: payload)
    }

    /// Forgets the impression + first-click marks so a later re-trigger re-arms both.
    func resetImpression(_ cepCampaignId: String) {
        digiaImpressed.remove(cepCampaignId)
        digiaClicked.remove(cepCampaignId)
    }

    /// Forgets every impression + first-click mark.
    func clearImpressions() {
        digiaImpressed.removeAll()
        digiaClicked.removeAll()
    }
}
