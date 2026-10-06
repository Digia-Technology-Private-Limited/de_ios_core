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

    /// Starts a survey. Returns false if a survey is already active or the
    /// config is empty.
    @discardableResult
    func start(
        payload: CEPTriggerPayload,
        config: SurveyConfigModel
    ) -> Bool {
        guard !config.nodes.isEmpty, !config.blocks.isEmpty else { return false }
        if state != nil { return false }
        tokenCounter += 1
        state = ActiveSurveyState(
            payload: payload,
            config: config,
            token: tokenCounter,
            startedAt: Date(),
            variableContext: buildVariableContext(
                schemas: config.variableSchemas,
                cepVars: payload.variables,
                campaignKey: payload.campaignKey
            )
        )
        return true
    }

    func dismiss() {
        state = nil
        progressReader = nil
    }

    /// The renderer's progress for the showing it draws, read when something
    /// other than the renderer ends the survey (a supersede), so that dismiss
    /// carries the same `abandoned_at_item` / `answered_count` a user close does.
    private var progressReader: (token: Int64, read: () -> (abandonedAtItem: Int, answeredCount: Int))?

    /// Called by the renderer for the showing `token`.
    func bindProgress(token: Int64, read: @escaping () -> (abandonedAtItem: Int, answeredCount: Int)) {
        guard state?.token == token else { return }
        progressReader = (token, read)
    }

    /// The active showing's progress, or nil when no renderer has drawn it.
    func progress() -> (abandonedAtItem: Int, answeredCount: Int)? {
        guard let reader = progressReader, reader.token == state?.token else { return nil }
        return reader.read()
    }
}
