import Foundation
import CoreGraphics

// Ported from Android `GuideConfigModel.kt` / `GuideStepModel.kt`.

enum GuideTarget: Equatable {
    case registeredAnchor(String)
    case anchorless(AnchorlessTarget)

    var anchorKey: String? {
        if case let .registeredAnchor(value) = self { return value }
        return nil
    }

    var anchorlessTarget: AnchorlessTarget? {
        if case let .anchorless(value) = self { return value }
        return nil
    }
}

struct GuideStepModel: Equatable {
    let id: String
    let sequenceOrder: Int
    let target: GuideTarget
    let displayStyle: String
    let widgetConfig: GuideStepWidgetConfig
    let advanceTrigger: String
    let autoDelayMs: Int?
    let delayInMs: Int?
    /// A tap inside this step's highlighted cutout reaches the widget underneath.
    let passThroughTap: Bool
    /// A tap inside this step's cutout also advances the guide, dismissing from the last
    /// step exactly like the outside-tap `next` path.
    let advanceOnTap: Bool

    var anchorKey: String { target.anchorKey ?? "" }
}

struct GuideConfigModel: Equatable {
    let id: String
    let multiStep: Bool
    let designWidth: CGFloat
    var steps: [GuideStepModel]
    /// Dashboard-declared variable schemas; resolved against CEP trigger variables
    /// at render time via `buildVariableContext()`.
    let variableSchemas: [VariableSchema]

    var isAnchorless: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.target.anchorlessTarget != nil }
    }
}
