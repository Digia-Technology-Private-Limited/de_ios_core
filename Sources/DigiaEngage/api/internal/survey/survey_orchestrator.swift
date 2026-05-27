import Foundation
import Combine

/// The survey currently routed for display. `token` is unique per showing so
/// the renderer can key a fresh in-progress state to it.
struct ActiveSurveyState: Equatable {
    let payload: InAppPayload
    let config: SurveyConfigModel
    let token: Int64
    let startedAt: Date
}

/// Holds the active survey. The in-progress answer state lives in the
/// renderer's `SurveyViewModel`; this only tracks which survey (if any) is on screen.
@MainActor
final class SurveyOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveSurveyState?

    private var tokenCounter: Int64 = 0

    /// Starts a survey. Returns false if another survey is already showing or
    /// the config is empty.
    @discardableResult
    func start(payload: InAppPayload, config: SurveyConfigModel) -> Bool {
        guard !config.nodes.isEmpty, !config.blocks.isEmpty else { return false }
        if state != nil { return false }
        tokenCounter += 1
        state = ActiveSurveyState(payload: payload, config: config, token: tokenCounter, startedAt: Date())
        return true
    }

    func dismiss() {
        state = nil
    }
}
