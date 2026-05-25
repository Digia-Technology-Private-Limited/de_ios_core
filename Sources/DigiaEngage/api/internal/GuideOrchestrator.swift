import Foundation
import Combine

/// Orchestrates the active guide campaign — tracks current step, handles
/// advance / dismiss. Mirrors the Android GuideOrchestrator.
@MainActor
final class GuideOrchestrator: ObservableObject {
    @Published private(set) var activeState: ActiveGuideState? = nil

    func start(campaign: GuideCampaign) {
        guard !campaign.steps.isEmpty else { return }
        activeState = ActiveGuideState(campaign: campaign, stepIndex: 0)
    }

    func advance() {
        guard let current = activeState else { return }
        if current.hasNext {
            activeState = ActiveGuideState(campaign: current.campaign, stepIndex: current.stepIndex + 1)
        } else {
            activeState = nil
        }
    }

    func dismiss() {
        activeState = nil
    }
}

// ── Domain models ─────────────────────────────────────────────────────────────

struct GuideCampaign {
    let campaignKey: String
    let steps: [GuideStep]
}

struct GuideStep {
    let id: String
    let anchorKey: String
    let displayStyle: String        // "tooltip" | "spotlight"
    let widgetConfig: GuideWidgetConfig
    let advanceTrigger: String      // "tap" | "auto"
    let autoDelayMs: Int?
}

struct GuideWidgetConfig {
    var bubbleBackgroundColor: String = "#1E40AF"
    var cornerRadius: CGFloat = 12
    var paddingH: CGFloat = 16
    var paddingV: CGFloat = 12
    var maxWidth: CGFloat = 280
    var entranceAnimation: String = "elastic"

    var arrowVisible: Bool = true
    var preferredDirection: String = "auto"
    var arrowSize: CGFloat = 10
    var arrowColor: String = "#1E40AF"

    // Overlay / spotlight
    var overlayVisible: Bool = false
    var overlayColor: String = "#000000"
    var overlayAlpha: Double = 0.6
    var dismissOnTap: Bool = false
    var cutoutShape: String = "rounded_rect"
    var cutoutCornerRadius: CGFloat = 12
    var cutoutPadding: CGFloat = 8

    // Content
    var titleText: String? = nil
    var titleColor: String = "#FFFFFF"
    var titleFontSize: CGFloat = 16

    var bodyText: String? = nil
    var bodyColor: String = "#FFFFFFCC"
    var bodyFontSize: CGFloat = 14

    var showStepIndicator: Bool = false
    var stepIndicatorColor: String = "#FFFFFFAA"

    // Actions
    var actions: [GuideActionConfig] = []
}

struct GuideActionConfig: Identifiable {
    let id: String
    let label: String
    let style: String               // "filled" | "ghost"
    let actionType: GuideActionType
    let backgroundColor: String
    let textColor: String
    let cornerRadius: CGFloat
}

enum GuideActionType { case dismiss, next, prev }

struct ActiveGuideState {
    let campaign: GuideCampaign
    let stepIndex: Int
    var currentStep: GuideStep { campaign.steps[stepIndex] }
    var hasNext: Bool { stepIndex < campaign.steps.count - 1 }
    var totalSteps: Int { campaign.steps.count }
}
