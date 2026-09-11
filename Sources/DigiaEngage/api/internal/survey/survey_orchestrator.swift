import Foundation
import Combine

/// The survey currently routed for display. `token` is unique per showing so
/// the renderer can key a fresh in-progress state to it.
struct ActiveSurveyState: Equatable {
    let payload: CEPTriggerPayload
    let config: SurveyConfigModel
    let token: Int64
    let startedAt: Date
    let variableContext: VariableContext
}

/// Holds the active survey. The in-progress answer state lives in the
/// renderer's `SurveyViewModel`; this only tracks which survey (if any) is on screen.
@MainActor
final class SurveyOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveSurveyState?

    private var tokenCounter: Int64 = 0

    /// Starts a survey. Returns false if an active survey cannot be replaced or
    /// the config is empty.
    @discardableResult
    func start(
        payload: CEPTriggerPayload,
        config: SurveyConfigModel,
        allowActiveReplacement: Bool = false
    ) -> Bool {
        guard !config.nodes.isEmpty, !config.blocks.isEmpty else { return false }
        if state != nil && !allowActiveReplacement { return false }
        tokenCounter += 1
        state = ActiveSurveyState(
            payload: payload,
            config: config,
            token: tokenCounter,
            startedAt: Date(),
            variableContext: buildVariableContext(
                schemas: config.variableSchemas,
                cepVars: payload.variables
            )
        )
        return true
    }

    func dismiss() {
        state = nil
    }
}
