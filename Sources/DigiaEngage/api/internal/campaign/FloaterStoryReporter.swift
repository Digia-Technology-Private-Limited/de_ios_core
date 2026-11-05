import Foundation

/// Reports a story floater's lifecycle, from the orchestrator's hooks and the
/// renderer's taps.
///
/// Reported through the PiP's own event vocabulary rather than a parallel set. Both
/// are `floater` campaigns and both answer the same questions — was the window seen,
/// was it moved, was its content opened, how long was the user inside — so one schema
/// keeps the dashboard's floater analytics reading both subtypes without a backend
/// change. "Expanded" there means "the story was open".
@MainActor
final class FloaterStoryReporter {
    init(_ ctx: SurfaceContext, _ orchestrator: FloaterStoryOrchestrator) {
        self.ctx = ctx
        self.orchestrator = orchestrator
    }

    private let ctx: SurfaceContext
    private let orchestrator: FloaterStoryOrchestrator

    func reportFloaterStoryImpression(_ state: ActiveFloaterStoryState) {
        ctx.impressed(
            state.payload,
            campaignKey: state.payload.campaignKey,
            viewed: FloaterEvent.Viewed(screenName: ctx.currentScreen))
    }

    /// Deliberately silent.
    ///
    /// The story's own viewer reports "Digia Step Viewed" per page, and the first of those fires as
    /// the story opens — which is exactly the moment this used to fire its property-less version.
    /// Emitting here as well would put two of the same event on the wire for one open, one of them
    /// with no page to attribute it to. The orchestrator still calls this because the *lifecycle*
    /// hook is real; only the reporting moved.
    func emitFloaterStoryStepViewed(_ state: ActiveFloaterStoryState) {}

    /// Silent for the same reason as `emitFloaterStoryStepViewed` — the viewer reports the close
    /// with the page the viewer left on, which is the half that makes drop-off measurable.
    func emitFloaterStoryStepDismissed(_ state: ActiveFloaterStoryState) {}

    func emitFloaterStoryDismissed(
        _ state: ActiveFloaterStoryState, _ reason: FloaterDismissReason,
        _ metrics: FloaterMetrics, _ wasVisible: Bool
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

    func emitFloaterStoryCompleted(_ state: ActiveFloaterStoryState) {
        ctx.recordCompleted(
            campaignKey: state.payload.campaignKey,
            cepCampaignId: state.payload.cepCampaignId)
    }

    /// A tap on the window — the campaign's own surface, so an experience-level click.
    ///
    /// Covers both the SDK's chrome (opening the story, the ×) and the author's own elements. The
    /// window is not a step: a story floater's steps are the pages of the story it opens, so a
    /// button drawn on the window is a click on the experience itself. Reporting it as a step click
    /// put window taps and page taps in the same bucket, and left a campaign whose window carries a
    /// CTA with no experience clicks at all.
    func reportFloaterStoryClicked(
        elementId: String,
        actionType: String,
        ctaRole: String,
        ctaLabel: String? = nil,
        actionUrl: String? = nil
    ) {
        guard let state = orchestrator.state else { return }
        ctx.events.toDigia(
            FloaterEvent.Clicked(
                elementId: elementId, actionType: actionType,
                // The window is the collapsed state; the story is the expanded one.
                pipState: orchestrator.storyOpen ? "expanded" : "collapsed",
                ctaRole: ctaRole,
                timeToActionMs: ctx.dwell.elapsedMs(state.payload.cepCampaignId),
                ctaLabel: ctaLabel,
                actionUrl: actionUrl
            ),
            payload: state.payload
        )
    }
}
