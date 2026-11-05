import Foundation

/// Reports the nudge on screen — its impression, clicks and dismissal.
///
/// The overlay itself lives in `DigiaOverlayController`, so this owns the
/// lifecycle reporting rather than the route.
///
/// Impression and Dismissed go to both CEP and Digia analytics (toBoth); a
/// CTA Click is a Digia-only engagement signal (toDigia).
@MainActor
final class NudgeOrchestrator {
    init(_ ctx: SurfaceContext) { self.ctx = ctx }

    private let ctx: SurfaceContext

    func reportNudgeImpression() {
        guard let nudge = ctx.sdk.controller.activeNudge else { return }
        ctx.sdk.controller.startNudgeAutoDismiss()
        ctx.impressed(
            nudge.payload,
            campaignKey: nudge.payload.campaignKey,
            viewed: NudgeEvent.Viewed(
                displayStyle: nudge.config.surface.displayType.displayStyle,
                screenName: ctx.currentScreen
            )
        )
    }

    func reportPrimaryCTAClick(
        payload: CEPTriggerPayload? = nil, elementId: String, isPrimary: Bool
    ) {
        guard isPrimary, let payload = payload ?? ctx.sdk.controller.activeNudge?.payload else { return }
        ctx.events.clicked(payload: payload, elementId: elementId)
    }

    func emitNudgeClick(
        elementId: String? = nil,
        ctaLabel: String? = nil,
        actionType: String? = nil,
        actionUrl: String? = nil,
        ctaRole: String? = nil
    ) {
        guard let payload = ctx.sdk.controller.activeNudge?.payload else { return }
        ctx.events.toDigia(
            NudgeEvent.Clicked(
                elementId: elementId,
                ctaLabel: ctaLabel,
                actionType: actionType,
                actionUrl: actionUrl,
                ctaRole: ctaRole,
                // ms since the nudge was viewed (peek — the nudge is still open).
                timeToActionMs: ctx.dwell.elapsedMs(payload.cepCampaignId)
            ),
            payload: payload
        )
    }

    func markNudgeDismissed(reason: DismissReason = .userClose) {
        guard let nudge = ctx.sdk.controller.activeNudge else { return }
        ctx.sdk.controller.dismissNudge()
        ctx.events.toBoth(
            .dismissed(reason: reason),
            NudgeEvent.Dismissed(
                dismissReason: reason.wire,
                dwellMs: ctx.dwell.consumeDwellMs(nudge.payload.cepCampaignId)
            ),
            payload: nudge.payload
        )
    }
}
