import Foundation

// Ported from Android `GuideConfigModel.kt` / `GuideStepModel.kt`.

struct GuideStepModel: Equatable {
    let id: String
    let sequenceOrder: Int
    let anchorKey: String
    let displayStyle: String
    let widgetConfig: GuideStepWidgetConfig
    let advanceTrigger: String
    let autoDelayMs: Int?
}

struct GuideConfigModel: Equatable {
    let id: String
    let multiStep: Bool
    let steps: [GuideStepModel]
    /// Dashboard-declared variable schemas; resolved against CEP trigger variables
    /// at render time via `buildVariableContext()`.
    let variableSchemas: [VariableSchema]
}
