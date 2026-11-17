import Foundation

/// Reports inline slots — carousel, banner, canvas and timer — as they paint
/// and are tapped.
///
/// Inline impressions fire at first render; dismissal fires at final removal.
/// Inline campaigns are never frequency-capped.
@MainActor
final class InlineReporter {
    init(_ ctx: SurfaceContext, _ controller: InlineCampaignController) {
        self.ctx = ctx
        self.controller = controller
    }

    private let ctx: SurfaceContext
    private let controller: InlineCampaignController

    func reportSlotFirstRender(_ payload: CEPTriggerPayload) {
        guard let campaign = ctx.sdk.findCampaign(payload) else { return }
        if case .inlineCanvas(let cfg) = campaign.config, controller.getCampaign(cfg.slotKey) != payload { return }
        var timerState: ResolvedTimerCanvas?
        if case .inlineCanvas(let cfg) = campaign.config, let runtime = cfg.statefulTimer {
            guard let resolved = runtime.resolve(schemas: campaign.variableSchemas, cepVars: payload.variables), resolved.canvas != nil else { return }
            timerState = resolved
        }
        let viewed: EngageAnalyticsEvent
        switch campaign.config {
        case .inline(let cfg):
            viewed = CarouselEvent.Viewed(
                itemTotal: cfg.items.count, slotKey: cfg.slotKey, screenName: ctx.currentScreen)
        case .banner(let cfg):
            viewed = BannerEvent.Viewed(slotKey: cfg.slotKey, screenName: ctx.currentScreen)
        case .story(let cfg):
            viewed = StoriesEvent.Viewed(
                itemTotal: cfg.items.count, slotKey: cfg.slotKey, screenName: ctx.currentScreen)
        case .inlineCanvas(let cfg):
            viewed = InlineCanvasEvent.Viewed(
                slotKey: cfg.slotKey,
                screenName: ctx.currentScreen
            )
        default:
            return
        }
        if let resolved = timerState {
            ctx.events.digiaTimerStateImpressionOnce(
                payload: payload,
                stateID: resolved.stateID,
                event: TimerAnalyticsEvent(event: viewed, timer: resolved.analyticsContext)
            )
        } else {
            ctx.events.digiaImpressionOnce(payload: payload, event: viewed)
        }
    }

    func reportInlineTimerStateRender(
        payload: CEPTriggerPayload,
        config: InlineCanvasConfig,
        resolved: ResolvedTimerCanvas
    ) {
        guard config.statefulTimer != nil, controller.getCampaign(config.slotKey) == payload else { return }
        ctx.events.digiaTimerStateImpressionOnce(
            payload: payload,
            stateID: resolved.stateID,
            event: TimerAnalyticsEvent(
                event: InlineCanvasEvent.Viewed(
                    slotKey: config.slotKey,
                    screenName: ctx.currentScreen
                ),
                timer: resolved.analyticsContext
            )
        )
    }

    /// A carousel item scrolled into view. `auto` = autoplay advance vs manual swipe.
    func reportCarouselStepViewed(
        payload: CEPTriggerPayload, itemIndex: Int, itemTotal: Int, auto: Bool
    ) {
        // The slot's Viewed comes first. The step gate fires as soon as the slot is exposed, which can be
        // before the slot's first-render report; the impression is sent once, so this only fixes the order (F13).
        reportSlotFirstRender(payload)
        ctx.events.toDigia(
            CarouselEvent.StepViewed(itemIndex: itemIndex, itemTotal: itemTotal, auto: auto),
            payload: payload
        )
    }

    func reportClassicCarouselContainerClicked(_ payload: CEPTriggerPayload) {
        ctx.events.clicked(payload: payload, elementId: "carousel_container")
    }

    func reportCarouselStepClicked(
        payload: CEPTriggerPayload, itemIndex: Int, action: EngageAction?
    ) {
        let actionType = action?.analyticsType
        let actionUrl = action?.analyticsURL
        // The first item tap also counts as an experience-level engagement click (once).
        ctx.events.digiaExperienceClickedOnce(
            payload: payload,
            event: CarouselEvent.Clicked(actionType: actionType, actionUrl: actionUrl)
        )
        ctx.events.toDigia(
            CarouselEvent.StepClicked(
                itemIndex: itemIndex,
                actionType: actionType,
                actionUrl: actionUrl
            ),
            payload: payload
        )
    }

    func reportBannerClicked(payload: CEPTriggerPayload, action: EngageAction?) {
        ctx.events.toDigia(
            BannerEvent.Clicked(
                actionType: action?.analyticsType,
                actionUrl: action?.analyticsURL
            ),
            payload: payload
        )
    }

    /// An element on an inline canvas was tapped.
    ///
    /// Reported through the nudge conversion events rather than an inline item
    /// funnel: a canvas has no items to walk, and it converts on a widget's
    /// action exactly as a nudge does. The dashboard reads the same `nudge`
    /// block for both, so the two stay consistent by construction.
    func emitInlineCanvasClick(
        payload: CEPTriggerPayload,
        elementId: String? = nil,
        ctaLabel: String? = nil,
        actionType: String? = nil,
        actionUrl: String? = nil,
        ctaRole: String? = nil,
        timerContext: TimerEventContext? = nil
    ) {
        var event: EngageAnalyticsEvent = NudgeEvent.Clicked(
            elementId: elementId,
            ctaLabel: ctaLabel,
            actionType: actionType,
            actionUrl: actionUrl,
            ctaRole: ctaRole,
            timeToActionMs: ctx.dwell.elapsedMs(payload.cepCampaignId)
        )
        if let timerContext { event = TimerAnalyticsEvent(event: event, timer: timerContext) }
        ctx.events.toDigia(event, payload: payload)
    }

    /// The author's Hide action removed an inline canvas from its slot.
    ///
    /// Bypasses the stickiness that keeps inline campaigns alive across
    /// navigation: an author who put a close control on the card is asking for
    /// exactly the opposite.
    func dismissInlineCanvas(
        slotKey: String,
        payload: CEPTriggerPayload,
        timerContext: TimerEventContext? = nil
    ) {
        if controller.getCampaign(slotKey) != payload { return }
        // The author's Hide: the one inline removal that is the user closing it.
        controller.dismissCampaign(slotKey, reason: .userClose)
        var event: EngageAnalyticsEvent = NudgeEvent.Dismissed(
            dwellMs: ctx.dwell.consumeDwellMs(payload.cepCampaignId)
        )
        if let timerContext { event = TimerAnalyticsEvent(event: event, timer: timerContext) }
        ctx.events.toDigia(event, payload: payload)
    }
}
