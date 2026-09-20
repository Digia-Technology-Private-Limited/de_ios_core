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
/// event models: the owning presentation gets the coarse ``DigiaExperienceEvent``
/// protocol via ``toCep(_:payload:)``; Digia analytics gets the rich, campaign-grouped
/// ``EngageAnalyticsEvent`` via ``toDigia(_:payload:)``. ``toBoth(_:_:payload:)``
/// fires a dual signal (e.g. a nudge impression). Also owns the first-render
/// impression dedup, an emission concern rather than widget state. Ported from
/// Android `internal/event/EngageEventEmitter.kt`.
@MainActor
final class EngageEventEmitter {
    /// Where an event actually goes — real delivery, or a live test's ACK
    /// redirect — decided once per call via `sink(for:)` rather than each
    /// method separately checking `isLiveTestCepId`.
    @MainActor
    private protocol EventSink {
        func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload)
        func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload)
        func onFirstImpression(payload: CEPTriggerPayload, event: EngageAnalyticsEvent)
    }

    @MainActor
    private final class RealEventSink: EventSink {
        let cep: PresentationSink
        let digia: DigiaAnalyticsSink

        init(cep: PresentationSink, digia: DigiaAnalyticsSink) {
            self.cep = cep
            self.digia = digia
        }

        func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
            eventLog.info(
                "[DigiaEvent] Event fired → CEP: \(String(describing: event), privacy: .public) | campaignKey=\(payload.campaignKey, privacy: .public) cepCampaignId=\(payload.cepCampaignId, privacy: .public)"
            )
            cep.deliver(event, payload: payload)
        }

        func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
            eventLog.info(
                "[DigiaEvent] Event fired → DIGIA: '\(event.eventName, privacy: .public)' (\(String(describing: type(of: event)), privacy: .public)) | campaignKey=\(payload.campaignKey, privacy: .public) cepCampaignId=\(payload.cepCampaignId, privacy: .public) properties=\(String(describing: event.properties), privacy: .public)"
            )
            digia.deliver(event, payload: payload)
        }

        func onFirstImpression(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
            toDigia(event, payload: payload)
            toCep(.impressed, payload: payload)
        }
    }

    @MainActor
    private final class LiveTestEventSink: EventSink {
        let onLiveTestShown: ((String) -> Void)?
        let onLiveTestDismissed: ((String, DismissReason, Bool) -> Void)?

        init(
            onLiveTestShown: ((String) -> Void)?,
            onLiveTestDismissed: ((String, DismissReason, Bool) -> Void)?
        ) {
            self.onLiveTestShown = onLiveTestShown
            self.onLiveTestDismissed = onLiveTestDismissed
        }

        func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
            // A live test has no CEP to mark, so this sink exists to turn the
            // two events a person watching the dashboard actually cares about
            // — it appeared, and how it ended — into the invocation's own
            // uplink.
            switch event {
            case .impressed:
                onLiveTestShown?(payload.cepCampaignId)
            case .dismissed(let reason, let completed):
                onLiveTestDismissed?(payload.cepCampaignId, reason, completed)
            case .clicked:
                break
            }
        }

        func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
            // Suppressed entirely — a live test must never reach real analytics.
        }

        func onFirstImpression(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
            onLiveTestShown?(payload.cepCampaignId)
        }
    }

    private let realSink: RealEventSink
    private let liveTestSink: LiveTestEventSink

    private func sink(for payload: CEPTriggerPayload) -> EventSink {
        isLiveTestCepId(payload.cepCampaignId) ? liveTestSink : realSink
    }

    /// `cepCampaignId`s that have already fired a Digia first-render impression.
    private var digiaImpressed: Set<String> = []

    /// `cepCampaignId`s that have already fired a Digia first-engagement click.
    private var digiaClicked: Set<String> = []
    private var timerImpressedStateByCampaign: [String: String] = [:]

    init(
        cep: PresentationSink,
        digia: DigiaAnalyticsSink,
        onLiveTestShown: ((String) -> Void)? = nil,
        onLiveTestDismissed: ((String, DismissReason, Bool) -> Void)? = nil
    ) {
        self.realSink = RealEventSink(cep: cep, digia: digia)
        self.liveTestSink = LiveTestEventSink(
            onLiveTestShown: onLiveTestShown,
            onLiveTestDismissed: onLiveTestDismissed
        )
    }

    /// Coarse lifecycle signal to the owning presentation only.
    func toCep(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        sink(for: payload).toCep(event, payload: payload)
    }

    /// Rich analytics signal to Digia only.
    func toDigia(_ event: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        sink(for: payload).toDigia(event, payload: payload)
    }

    /// Fires a coarse CEP signal and its rich Digia counterpart together.
    func toBoth(_ cepEvent: DigiaExperienceEvent, _ digiaEvent: EngageAnalyticsEvent, payload: CEPTriggerPayload) {
        toCep(cepEvent, payload: payload)
        toDigia(digiaEvent, payload: payload)
    }

    /// Records `event` (a campaign "Viewed") to Digia the first time its campaign
    /// renders, deduped by `cepCampaignId`. CEP impressions share this dedup.
    func digiaImpressionOnce(payload: CEPTriggerPayload, event: EngageAnalyticsEvent) {
        guard digiaImpressed.insert(payload.cepCampaignId).inserted else { return }
        sink(for: payload).onFirstImpression(payload: payload, event: event)
    }

    func digiaTimerStateImpressionOnce(
        payload: CEPTriggerPayload,
        stateID: String,
        event: EngageAnalyticsEvent
    ) {
        guard timerImpressedStateByCampaign[payload.cepCampaignId] != stateID else { return }
        timerImpressedStateByCampaign[payload.cepCampaignId] = stateID
        if digiaImpressed.insert(payload.cepCampaignId).inserted {
            toCep(.impressed, payload: payload)
        }
        toDigia(event, payload: payload)
    }

    func inlineRemoved(_ payload: CEPTriggerPayload, reason: DismissReason = .userClose) {
        resetImpression(payload.cepCampaignId)
        toCep(.dismissed(reason: reason), payload: payload)
    }

    func clicked(payload: CEPTriggerPayload, elementId: String) {
        toCep(.clicked(elementID: elementId), payload: payload)
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
        timerImpressedStateByCampaign.removeValue(forKey: cepCampaignId)
    }

    /// Forgets every impression + first-click mark.
    func clearImpressions() {
        digiaImpressed.removeAll()
        digiaClicked.removeAll()
        timerImpressedStateByCampaign.removeAll()
    }
}
