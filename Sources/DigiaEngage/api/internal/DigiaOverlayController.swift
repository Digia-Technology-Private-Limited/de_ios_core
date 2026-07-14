import SwiftUI
import Combine

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: CEPTriggerPayload
}

@MainActor
final class DigiaOverlayController: ObservableObject {
    @Published private(set) var activeNudge: DigiaNudgePresentation?
    @Published private(set) var activeStoryOverlay: InlineStoryOverlayState?

    /// Sets the nudge state. Impression/dismissal analytics are emitted by
    /// ``SDKInstance`` (`reportNudgeImpression` / `markNudgeDismissed`), not here.
    func showNudge(_ presentation: DigiaNudgePresentation) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            activeNudge = presentation
        }
    }

    func dismissNudge() {
        guard activeNudge != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            activeNudge = nil
        }
    }

    /// Clears the active nudge instantly with no animation and no event.
    /// Used when the JS bundle reloads so a stale overlay doesn't persist.
    func forceNudgeDismiss() {
        activeNudge = nil
    }

    func showStoryOverlay(config: InlineStoryConfig, initialIndex: Int, payload: CEPTriggerPayload)
    {
        let state = InlineStoryOverlayState(
            config: config,
            initialIndex: initialIndex,
            payload: payload
        )
        activeStoryOverlay = state
        DigiaStoryPresenter.shared.present(state: state)
    }

    func dismissStoryOverlay() {
        activeStoryOverlay = nil
        DigiaStoryPresenter.shared.dismiss()
    }
}
