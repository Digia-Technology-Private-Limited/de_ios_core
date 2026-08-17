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

    var anchorKey: String { target.anchorKey ?? "" }
}

struct GuideConfigModel: Equatable {
    let id: String
    let multiStep: Bool
    let designWidth: CGFloat
    let steps: [GuideStepModel]
    /// Dashboard-declared variable schemas; resolved against CEP trigger variables
    /// at render time via `buildVariableContext()`.
    let variableSchemas: [VariableSchema]

    var isAnchorless: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.target.anchorlessTarget != nil }
    }
}
