import SwiftUI

/// Hosts an authored Canvas inside a `DigiaSlot`.
///
/// Thin by design: `InlineCampaignCanvasView` owns the sizing rule, and this
/// view owns what the slot owns — the campaign's variables, its analytics, and
/// what Hide means here.
@MainActor
struct DigiaInlineCanvasView: View {
    let config: InlineCanvasConfig
    let payload: CEPTriggerPayload
    @Environment(\.scenePhase) private var scenePhase
    @State private var tick: UInt64 = 0

    var body: some View {
        let _ = tick
        let variables = buildVariableContext(
            schemas: config.variableSchemas,
            cepVars: payload.variables
        )
        let resolved = config.statefulTimer?.resolve(payload.variables)
        Group {
            if config.statefulTimer == nil {
                canvas(config.canvas, remainingSeconds: nil, variables: variables, timerContext: nil)
            } else if let resolved, let selectedCanvas = resolved.canvas {
                canvas(
                    selectedCanvas,
                    remainingSeconds: resolved.remainingSeconds,
                    variables: variables,
                    timerContext: resolved.analyticsContext(
                        nowMs: config.statefulTimer!.timeAnchor.nowMs()
                    )
                )
                .id(resolved.stateID)
            }
        }
        .task(id: resolved?.stateID) {
            if let resolved, resolved.canvas != nil {
                SDKInstance.shared.reportInlineTimerStateRender(
                    payload: payload,
                    config: config,
                    resolved: resolved
                )
            }
        }
        .task(id: "\(scenePhase)-\(payload.cepCampaignId)") {
            guard let runtime = config.statefulTimer, scenePhase == .active else { return }
            while !Task.isCancelled {
                tick &+= 1
                let now = runtime.timeAnchor.nowMs()
                let wait = UInt64(max(1, min(1_000, 1_000 - (now % 1_000))))
                try? await Task.sleep(nanoseconds: wait * 1_000_000)
            }
        }
    }

    private func canvas(
        _ canvas: CampaignCanvas,
        remainingSeconds: Int64?,
        variables: VariableContext?,
        timerContext: TimerEventContext?
    ) -> some View {
        InlineCampaignCanvasView(
            canvas: canvas,
            designWidth: CGFloat(config.designWidth),
            cornerRadius: CGFloat(config.cornerRadius),
            margin: config.margin,
            onAction: { request in
                perform(request, variables: variables, timerContext: timerContext)
            }
        )
        .environment(\.timerRemainingSeconds, remainingSeconds)
        // Canvas widgets report what happened to them; this is where it becomes a campaign event.
        //
        // The widgets cannot do this themselves — a carousel has no idea which campaign it is part
        // of, and shouldn't. Mapping here means a canvas carousel emits the *same* events the media
        // carousel it replaces emits, so the two are comparable and a migration doesn't reset the
        // funnel. Indices arrive 0-based and go out 1-based, which is the wire's convention.
        .environment(\.canvasInteractions, CanvasInteractionReporter { interaction in
            switch interaction {
            case let .carouselSlideViewed(index, total, auto):
                SDKInstance.shared.reportCarouselStepViewed(
                    payload: payload, itemIndex: index + 1, itemTotal: total, auto: auto
                )
            case .storyOpened:
                SDKInstance.shared.reportStoryOpened(payload)
            case let .storyPageViewed(index, total):
                SDKInstance.shared.reportStoryStepViewed(
                    payload, itemIndex: index + 1, itemTotal: total
                )
            case let .storyPageDismissed(index, _):
                SDKInstance.shared.reportStoryStepDismissed(payload, itemIndex: index + 1)
            case let .storyCompleted(total, timeToCompleteMs):
                SDKInstance.shared.reportStoryCompleted(
                    payload,
                    itemTotal: total,
                    timeToCompleteMs: timeToCompleteMs.map(Int64.init)
                )
            }
        })
    }

    private func perform(
        _ request: CampaignCanvasActionRequest,
        variables: VariableContext?,
        timerContext: TimerEventContext?
    ) {
        guard !request.actions.isEmpty else { return }
        let action = request.actions.first?.resolved(with: variables)
        // A tap inside a slide or a page is a *step* click, matching what the legacy carousel and
        // story report; a tap on the card itself stays a canvas click.
        switch request.step?.kind {
        case .carouselSlide:
            SDKInstance.shared.reportCarouselStepClicked(
                payload: payload, itemIndex: (request.step?.index ?? 0) + 1, action: action
            )
        case .storyPage:
            SDKInstance.shared.reportStoryStepClicked(
                payload,
                itemIndex: (request.step?.index ?? 0) + 1,
                ctaLabel: request.label,
                actionType: action?.analyticsType,
                actionUrl: action?.analyticsURL
            )
        case nil:
            SDKInstance.shared.emitInlineCanvasClick(
                payload: payload,
                elementId: request.elementId,
                ctaLabel: request.label,
                actionType: action?.analyticsType,
                actionUrl: action?.analyticsURL,
                ctaRole: request.isPrimary ? "primary" : "secondary",
                timerContext: timerContext
            )
        }
        // Hide means something slot-specific here: clear this slot for the
        // session. That deliberately bypasses the stickiness which otherwise
        // keeps an inline campaign alive across navigation.
        let dismiss = {
            SDKInstance.shared.dismissInlineCanvas(
                slotKey: config.slotKey,
                payload: payload,
                timerContext: timerContext
            )
        }
        let hides = request.actions.contains { if case .dismiss = $0 { true } else { false } }
        Task {
            await SDKInstance.shared.executeActionFlow(
                request.actions,
                variables: variables,
                localActionExecutor: LocalActionExecutor(dismiss: dismiss)
            )
            if hides { dismiss() }
        }
    }
}
