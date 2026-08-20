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

    var body: some View {
        let variables = buildVariableContext(
            schemas: config.variableSchemas,
            cepVars: payload.variables
        )
        InlineCampaignCanvasView(
            canvas: config.canvas,
            designWidth: CGFloat(config.designWidth),
            cornerRadius: CGFloat(config.cornerRadius),
            margin: config.margin,
            onAction: { request in
                perform(request, variables: variables)
            }
        )
    }

    private func perform(_ request: CampaignCanvasActionRequest, variables: VariableContext?) {
        guard !request.actions.isEmpty else { return }
        let action = request.actions.first?.resolved(with: variables)
        SDKInstance.shared.emitInlineCanvasClick(
            payload: payload,
            elementId: request.elementId,
            ctaLabel: request.label,
            actionType: action?.analyticsType,
            actionUrl: action?.analyticsURL,
            ctaRole: request.isPrimary ? "primary" : "secondary"
        )
        // Hide means something slot-specific here: clear this slot for the
        // session. That deliberately bypasses the stickiness which otherwise
        // keeps an inline campaign alive across navigation.
        let dismiss = {
            SDKInstance.shared.dismissInlineCanvas(slotKey: config.slotKey, payload: payload)
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
