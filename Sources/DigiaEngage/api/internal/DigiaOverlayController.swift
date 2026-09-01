import SwiftUI
import Combine

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: CEPTriggerPayload
}

@MainActor
final class DigiaOverlayController: ObservableObject {
    @Published private(set) var activeNudge: DigiaNudgePresentation? {
        didSet {
            nudgeAutoDismissTask?.cancel()
            nudgeAutoDismissTask = nil
        }
    }
    private var nudgeAutoDismissTask: Task<Void, Never>?
    @Published private(set) var activeStoryOverlay: InlineStoryOverlayState?

    var onAction: ((_ actionType: String, _ url: String, _ payload: CEPTriggerPayload) -> Bool)?

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

    /// Starts on appearance and stays owned by this nudge when child views appear.
    func startNudgeAutoDismiss() {
        guard nudgeAutoDismissTask == nil, let nudge = activeNudge,
              nudge.config.canvas != nil,
              nudge.config.surface.isFullScreen else { return }
        let afterMs = nudge.config.surface.autoDismissAfterMs
        guard afterMs > 0 else { return }
        let nanoseconds = UInt64(afterMs) * 1_000_000
        nudgeAutoDismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled, self?.activeNudge?.id == nudge.id else { return }
            SDKInstance.shared.markNudgeDismissed()
        }
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
