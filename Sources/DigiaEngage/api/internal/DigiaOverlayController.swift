import SwiftUI
import Combine

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: InAppPayload
}

@MainActor
final class DigiaOverlayController: ObservableObject {
    @Published private(set) var activePayload: InAppPayload?
    @Published private(set) var activeNudge: DigiaNudgePresentation?
    @Published private(set) var activeStoryOverlay: InlineStoryOverlayState?

    var onEvent: ((DigiaExperienceEvent, InAppPayload) -> Void)?

    var onAction: ((_ actionType: String, _ url: String, _ payload: InAppPayload) -> Void)?

    func show(_ payload: InAppPayload) {
        activePayload = payload
    }

    func dismiss() {
        activePayload = nil
    }

    func showNudge(_ presentation: DigiaNudgePresentation) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            activeNudge = presentation
        }
        onEvent?(.impressed, presentation.payload)
    }

    func dismissNudge() {
        guard let presentation = activeNudge else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            activeNudge = nil
        }
        onEvent?(.dismissed, presentation.payload)
    }

    /// Clears the active nudge instantly with no animation and no event.
    /// Used when the JS bundle reloads so a stale overlay doesn't persist.
    func forceNudgeDismiss() {
        activeNudge = nil
    }

    func showStoryOverlay(config: InlineStoryConfig, initialIndex: Int, payload: InAppPayload) {
        let state = InlineStoryOverlayState(
            config: config,
            initialIndex: initialIndex,
            payload: payload
        )
        activeStoryOverlay = state
        // The full-screen story is presented in its own dedicated UIWindow
        // (DigiaStoryWindowPresenter), not as an in-host SwiftUI overlay. A
        // separate key window sits above all React Native content and owns its
        // touches outright, so taps / swipes / the CTA work without competing
        // with Fabric's RCTSurfaceTouchHandler.
        DigiaStoryWindowPresenter.shared.present(state: state)
    }

    func dismissStoryOverlay() {
        activeStoryOverlay = nil
        DigiaStoryWindowPresenter.shared.dismiss()
    }
}
