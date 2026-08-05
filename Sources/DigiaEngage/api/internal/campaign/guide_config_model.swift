import Foundation

// Ported from Android `GuideConfigModel.kt` / `GuideStepModel.kt`.

struct GuideStepModel: Equatable {
    let id: String
    let sequenceOrder: Int
    let anchorKey: String
    let semanticTarget: SemanticTarget?
    let geometryTarget: TypedGeometryTargetV1?
    /// Stable backend-authored step identifier used for O(1) Assisted Geometry lookup.
    let assistedStepId: String?
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
    /// Validated once for the complete campaign before any guide presentation begins.
    let assistedCampaign: PreparedAssistedCampaignV1?
}
