import SwiftUI

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: CEPTriggerPayload
}

@MainActor
final class DigiaOverlayController: ObservableObject {
    /// Generic typed-overlay path (RN/JS-driven campaigns that arrive without a
    /// resolvable `campaignKey`). Carries the rich ``InAppPayload`` so the host
    /// can route by display type; it is not part of the analytics event flow.
    @Published private(set) var activePayload: InAppPayload?
    @Published private(set) var activeNudge: DigiaNudgePresentation?
    @Published private(set) var activeStoryOverlay: InlineStoryOverlayState?

    func show(_ payload: InAppPayload) {
        activePayload = payload
    }

    func dismiss() {
        activePayload = nil
    }

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

    func showStoryOverlay(config: InlineStoryConfig, initialIndex: Int, payload: CEPTriggerPayload) {
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
