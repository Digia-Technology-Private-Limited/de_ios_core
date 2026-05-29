import Foundation
import Combine

// Ported from Android `GuideOrchestrator.kt`. Drives a multi-step guide
// (tooltip / spotlight) over the existing anchor + overlay primitives.

struct ActiveGuideState: Equatable {
    let campaign: CampaignModel
    let stepIndex: Int

    var steps: [GuideStepModel] { campaign.guideConfig?.steps ?? [] }
    var currentStep: GuideStepModel? { steps.indices.contains(stepIndex) ? steps[stepIndex] : nil }
    var hasNext: Bool { stepIndex < steps.count - 1 }
}

@MainActor
final class GuideOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveGuideState?

    func start(_ campaign: CampaignModel) {
        guard campaign.campaignType == "guide",
              let guideConfig = campaign.guideConfig,
              !guideConfig.steps.isEmpty
        else { return }
        state = ActiveGuideState(campaign: campaign, stepIndex: 0)
    }

    func advance() {
        guard let current = state else { return }
        state = current.hasNext
            ? ActiveGuideState(campaign: current.campaign, stepIndex: current.stepIndex + 1)
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
