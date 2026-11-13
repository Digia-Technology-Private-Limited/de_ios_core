import SwiftUI
import Combine
internal import DigiaVideoEngine

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: CEPTriggerPayload
    /// The rail card's player on its way to the viewer, when a playing card was tapped.
    var handover: StoryHandover? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.config == rhs.config && lhs.initialIndex == rhs.initialIndex && lhs.payload == rhs.payload
            && lhs.handover === rhs.handover
    }
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
    /// The classic inline story's own layer (the one `StoryLayer` every story opens in).
    private let storyLayer = StoryLayer()

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
            SDKInstance.shared.markNudgeDismissed(reason: .autoTimeout)
        }
    }

    func showStoryOverlay(
        config: InlineStoryConfig, initialIndex: Int, payload: CEPTriggerPayload, handover: StoryHandover? = nil
    ) {
        // A story already showing gives up any handover it never used.
        activeStoryOverlay?.handover?.release()
        let state = InlineStoryOverlayState(
            config: config,
            initialIndex: initialIndex,
            payload: payload,
            handover: handover
        )
        activeStoryOverlay = state
        storyLayer.present(fadeIn: true, onEscape: { [weak self] in self?.dismissStoryOverlay() }) {
            InlineStoryOverlayContent(state: state)
                .environment(\.digiaCampaignKey, state.payload.campaignKey)
        }
    }

    func dismissStoryOverlay() {
        // Never left held if the viewer did not get to use it (no top controller to present on).
        activeStoryOverlay?.handover?.release()
        activeStoryOverlay = nil
        storyLayer.dismiss()
    }
}
