import Foundation
import Combine

// Ported from Android `GuideOrchestrator.kt`. Drives a multi-step guide
// (tooltip / spotlight) over the existing anchor + overlay primitives.

struct ActiveGuideState: Equatable {
    let campaign: CampaignModel
    let stepIndex: Int
    /// The original trigger payload, retained so lifecycle events reuse the CEP's
    /// identity/metadata instead of a synthesized one (matches nudge/survey).
    let payload: CEPTriggerPayload

    /// Trigger-supplied variables for `{{ placeholder }}` interpolation.
    var variables: [String: String]? { payload.variables }
    var steps: [GuideStepModel] { campaign.guideConfig?.steps ?? [] }
    var currentStep: GuideStepModel? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    var hasNext: Bool { stepIndex < steps.count - 1 }
}

@MainActor
final class GuideOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveGuideState?

    func start(_ campaign: CampaignModel, payload: CEPTriggerPayload) {
        guard campaign.campaignType == "guide",
              let guideConfig = campaign.guideConfig,
              !guideConfig.steps.isEmpty
        else { return }
        state = ActiveGuideState(campaign: campaign, stepIndex: 0, payload: payload)
    }

    func advance() {
        guard let current = state else { return }
        state = current.hasNext
            ? ActiveGuideState(campaign: current.campaign, stepIndex: current.stepIndex + 1, payload: current.payload)
            : nil
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
