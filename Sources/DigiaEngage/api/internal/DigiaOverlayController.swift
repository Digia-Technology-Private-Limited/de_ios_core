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
            nudgeImpressed = false
        }
    }
    private var nudgeAutoDismissTask: Task<Void, Never>?
    /// Whether this presentation already reported its impression. SwiftUI can run
    /// `onAppear` more than once for one presentation; Viewed is sent once.
    var nudgeImpressed = false
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
    /// Any authored auto-dismiss is honored on every surface. The dashboard
    /// authors it for full-screen nudges only; the SDK stays ready for more.
    func startNudgeAutoDismiss() {
        guard nudgeAutoDismissTask == nil, let nudge = activeNudge else { return }
        let afterMs = nudge.config.surface.autoDismissAfterMs
        guard afterMs > 0 else { return }
        let nanoseconds = UInt64(afterMs) * 1_000_000
        nudgeAutoDismissTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) }
            catch { return }
            guard !Task.isCancelled, self?.activeNudge?.id == nudge.id else { return }
            SDKInstance.shared.nudgeOrchestrator.markNudgeDismissed(reason: .autoTimeout)
        }
    }

    /// Opens the story viewer, answering whether it was shown.
    ///
    /// The "story open" state is recorded only once UIKit accepted the present: a story that could not
    /// be shown (no screen to present from, one mid-transition, or a refused present) would otherwise
    /// leave the SDK believing a story is open with nothing on screen. That failure is recorded as
    /// `story_present_failed`.
    @discardableResult
    func showStoryOverlay(config: InlineStoryConfig, initialIndex: Int, payload: CEPTriggerPayload) -> Bool
    {
        let state = InlineStoryOverlayState(
            config: config,
            initialIndex: initialIndex,
            payload: payload
        )
        if let cause = DigiaStoryPresenter.shared.present(state: state) {
            storyLog.w(
                "Story not shown — \(cause)",
                campaign: payload.campaignKey,
                stage: .render,
                reason: TimelineReason.storyPresentFailed,
                extras: ["cause": cause]
            )
            return false
        }
        activeStoryOverlay = state
        return true
    }

    func dismissStoryOverlay() {
        activeStoryOverlay = nil
        DigiaStoryPresenter.shared.dismiss()
    }
}

private let storyLog = DigiaLogger()
