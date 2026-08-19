import Foundation
import Combine

// Ported from Android `GuideOrchestrator.kt`. Drives a multi-step guide
// (tooltip / spotlight) over the existing anchor + overlay primitives.

struct ActiveGuideState: Equatable {
    /// Monotonic identity for one guide presentation. Step transitions retain
    /// it so asynchronous image work cannot dismiss a newer presentation.
    let token: Int64
    let campaign: CampaignModel
    let stepIndex: Int
    /// The original trigger payload, retained so lifecycle events reuse the CEP's
    /// identity/metadata instead of a synthesized one (matches nudge/survey).
    let payload: CEPTriggerPayload

    var steps: [GuideStepModel] { campaign.guideConfig?.steps ?? [] }

    /// Resolved variable context: dashboard schemas merged with CEP trigger
    /// variables (CEP wins, empty CEP falls through to fallbackValue). Used by
    /// `GuideOverlayView` to interpolate `{{ placeholder }}` copy and arithmetic.
    var variableContext: VariableContext {
        let schemas = campaign.guideConfig?.variableSchemas ?? []
        return buildVariableContext(schemas: schemas, cepVars: payload.variables)
    }
    var currentStep: GuideStepModel? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    var hasNext: Bool { stepIndex < steps.count - 1 }
    var hasPrevious: Bool { stepIndex > 0 }
}

@MainActor
final class GuideOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveGuideState?
    private var tokenCounter: Int64 = 0

    func start(_ campaign: CampaignModel, payload: CEPTriggerPayload) {
        guard campaign.campaignType == "guide",
              let guideConfig = campaign.guideConfig,
              !guideConfig.steps.isEmpty
        else { return }
        tokenCounter &+= 1
        state = ActiveGuideState(token: tokenCounter, campaign: campaign, stepIndex: 0, payload: payload)
    }

    func advance() {
        guard let current = state else { return }
        state = current.hasNext
            ? ActiveGuideState(token: current.token, campaign: current.campaign, stepIndex: current.stepIndex + 1, payload: current.payload)
            : nil
    }

    func previous() {
        guard let current = state, current.hasPrevious else { return }
        state = ActiveGuideState(
            token: current.token,
            campaign: current.campaign,
            stepIndex: current.stepIndex - 1,
            payload: current.payload
        )
    }

    func dismiss() {
        state = nil
    }

    /// Dismiss only if the active guide matches the given campaign key.
    func dismissIfActive(campaignKey: String) {
        if state?.campaign.campaignKey == campaignKey {
            state = nil
        }
    }
}
