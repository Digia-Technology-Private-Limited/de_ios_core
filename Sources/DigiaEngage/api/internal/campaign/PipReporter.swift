import Foundation

/// Reports a PiP's lifecycle, from the orchestrator's hooks and the renderer's
/// taps.
///
/// The PiP is called a floater here, so the vocabulary is the existing
/// `FloaterEvent` one.
///
/// Impression, Dismissed, and Completed go to both CEP and Digia analytics —
/// except Completed, which has no CEP case. Step/chrome/CTA signals are
/// Digia-only engagement signals, the same convention as the nudge's CTA
/// click. Called from `FloaterOrchestrator`'s constructor-injected callbacks
/// (state/metrics are the values *handed to* them, never re-read from the
/// orchestrator, which is about to be nulled by the time `onDismissed` runs)
/// or directly from the floater views for chrome taps.
@MainActor
final class PipReporter {
    init(_ ctx: SurfaceContext, _ orchestrator: FloaterOrchestrator) {
        self.ctx = ctx
        self.orchestrator = orchestrator
    }

    private let ctx: SurfaceContext
    private let orchestrator: FloaterOrchestrator

    func reportFloaterImpression(_ state: ActiveFloaterState) {
        ctx.impressed(
            state.payload,
            campaignKey: state.payload.campaignKey,
            viewed: FloaterEvent.Viewed(screenName: ctx.currentScreen))
    }

    /// SDK chrome click: expand, collapse, mute/unmute, play/pause. **Never** the
    /// × — that routes straight to `dismissFloater`/`endFloaterExpanded` with no
    /// Clicked report (see `FloaterEvent.Clicked`'s kdoc; this exact bug already
    /// drove dismissal rate to a permanent 0% once).
    /// `pipState` is derived here from the live surface, not caller-supplied, so
    /// it can never go stale relative to what actually happened.
    func reportFloaterClicked(elementId: String, actionType: String, ctaRole: String) {
        guard let state = orchestrator.state else { return }
        ctx.events.toDigia(
            FloaterEvent.Clicked(
                elementId: elementId, actionType: actionType,
                pipState: orchestrator.surface == .expanded ? "expanded" : "collapsed",
                ctaRole: ctaRole,
                timeToActionMs: ctx.dwell.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    /// An authored CTA tapped inside the expanded content — the real conversion, as
    /// opposed to `reportFloaterClicked`'s SDK chrome. Called from
    /// `performFloaterCanvasAction` (`floater_overlay_view.swift`), the `onAction`
    /// callback `FloaterExpandedContentView` hands to `CampaignCanvasView`.
    ///
    /// No `ctaRole` parameter, unlike `reportFloaterClicked` — every authored CTA here
    /// is a genuine conversion with no chrome/content ambiguity, so `FloaterEvent
    /// .StepClicked`'s own default (`"primary"`) applies.
    func reportFloaterStepClicked(
        elementId: String, ctaLabel: String, actionType: String?, actionUrl: String?
    ) {
        guard let state = orchestrator.state else { return }
        ctx.events.toDigia(
            FloaterEvent.StepClicked(
                elementId: elementId, ctaLabel: ctaLabel, actionType: actionType,
                actionUrl: actionUrl,
                timeToActionMs: ctx.dwell.elapsedMs(state.payload.cepCampaignId)
            ),
            payload: state.payload
        )
    }

    func emitFloaterStepViewed(_ state: ActiveFloaterState) {
        ctx.events.toDigia(FloaterEvent.StepViewed(), payload: state.payload)
    }

    func emitFloaterStepDismissed(_ state: ActiveFloaterState) {
        ctx.events.toDigia(FloaterEvent.StepDismissed(), payload: state.payload)
    }

    func emitFloaterDismissed(
        _ state: ActiveFloaterState, _ reason: FloaterDismissReason, _ metrics: FloaterMetrics,
        _ wasVisible: Bool
    ) {
        if !wasVisible {
            ctx.events.toCep(.dismissed(reason: reason.presentationReason), payload: state.payload)
            return
        }
        ctx.events.toBoth(
            .dismissed(reason: reason.presentationReason),
            FloaterEvent.Dismissed(
                dismissReason: reason.wire,
                dwellMs: ctx.dwell.consumeDwellMs(state.payload.cepCampaignId),
                moves: metrics.moves, expands: metrics.expands,
                engagedMs: metrics.engagedMs, lastPosition: metrics.lastPosition
            ),
            payload: state.payload
        )
    }

    func emitFloaterCompleted(_ state: ActiveFloaterState) {
        ctx.recordCompleted(
            campaignKey: state.payload.campaignKey,
            cepCampaignId: state.payload.cepCampaignId)
        ctx.events.toDigia(FloaterEvent.Completed(), payload: state.payload)
    }
}
