/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Records one delivery's whole life on the campaign timeline.
///
/// **One more observer of the presentation lifecycle**, sitting beside the
/// analytics listener rather than as instrumentation scattered across the
/// surfaces. That is what makes the timeline free: the v2 contract already
/// produces the lifecycle as structured, correlated events, so subscribing once
/// here covers every campaign type and every CEP identically — and a new
/// surface is on the timeline the day it is written, without being told.
///
/// It is also the *only* owner of these four rows. The console line for the
/// terminal outcome does not live in ``PresentationController``'s settle path:
/// it belongs here so that one fact still prints once, and so the stage mapping
/// below is the only place in the SDK that exists.
///
/// ```
///   deliver() ──► observeDelivery() ──► Delivered       (trigger)
///                    │
///                    ├─ displayed ───────► Displayed      (render)
///                    ├─ clicked ─────────► Clicked        (interaction)
///                    └─ outcome ─┬─ dismissed ──────►     (interaction)
///                                └─ dropped ────────►     (trigger|gating|render)
/// ```
@MainActor
func observeDelivery(_ controller: PresentationController) {
    let campaignKey = controller.trigger.campaignKey
    let id = controller.id

    log.d(
        "Delivered (presentationId=\(id))",
        campaign: campaignKey,
        stage: .trigger,
        reason: TimelineReason.cepTriggerReceived,
        presentationId: id,
        extras: ["cepCampaignId": controller.trigger.cepCampaignId]
    )

    // The unsubscribe closure is discarded on purpose: settlement clears every
    // listener, and this observer lives exactly as long as the presentation.
    _ = controller.presentation.onSignal { signal in
        switch signal {
        case .displayed:
            log.d(
                "Displayed (presentationId=\(id))",
                campaign: campaignKey,
                stage: .render,
                reason: TimelineReason.displayed,
                presentationId: id
            )
        case .clicked(let elementId):
            let element = elementId.map { "elementId=\($0), " } ?? ""
            log.d(
                "Clicked (\(element)presentationId=\(id))",
                campaign: campaignKey,
                stage: .interaction,
                reason: TimelineReason.clicked,
                presentationId: id,
                extras: elementId.map { ["elementId": $0] }
            )
        }
    }

    Task { @MainActor in
        // Awaiting rather than polling: an already-settled presentation — the
        // synchronous-drop path — resolves immediately, so a drop that happened
        // before this line ran still gets its row.
        let outcome = await controller.presentation.outcome.value
        switch outcome {
        case .dismissed(let reason, _):
            log.d(
                "Dismissed — \(reason.value) (presentationId=\(id))",
                campaign: campaignKey,
                stage: .interaction,
                // The delivery enums *are* the timeline's reasons here — no
                // conversion, no twin symbol. See ``DiagnosticReason``.
                reason: reason,
                presentationId: id
            )
        case .dropped(let reason, _):
            log.d(
                "Dropped — \(reason.value) (presentationId=\(id))",
                campaign: campaignKey,
                stage: stageOf(reason),
                reason: reason,
                presentationId: id
            )
        }
    }
}

/// Which beat of the journey a drop happened on.
///
/// The only reason→stage mapping in the SDK. Everything else passes a stage
/// explicitly, because everything else knows where it is; a drop is the one
/// case where the answer lives in the reason.
///
/// `cancelled` and `pluginDetached` are the two the vocabulary table did not
/// originally place. Both mean the owner withdrew a campaign that was already
/// on its way to the screen, so they sit with the other render-stage endings
/// rather than back at the trigger.
func stageOf(_ reason: DropReason) -> TimelineStage {
    switch reason {
    case .notInitialized, .unknownCampaignKey:
        return .trigger
    case .frequencyCapped, .screenNotTargeted, .surfaceBusy, .superseded:
        return .gating
    case .invalidConfig, .anchorNotRegistered, .hostNotMounted, .timeout,
        .cancelled, .pluginDetached, .error:
        return .render
    }
}
