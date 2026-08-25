import SwiftUI

// The story floater's showing, from routing to teardown.
//
// Deliberately much smaller than `FloaterOrchestrator`, and the reason is worth stating:
// a PiP's whole design rests on owning an `AVPlayer` that outlives its view, because the
// window grows into full screen without re-parenting the media. A story floater has no
// such surface. Its window is a canvas and its story is a `fullScreenCover` — presented
// over everything, torn down on its own. So there is nothing here to hoist out of the
// view tree beyond the showing itself, and no media wait to hold the window back.
//
// Like the PiP's, it never takes the display lock: the window can sit on a screen for
// minutes, and blocking every other campaign for that long is not acceptable.

/// The story floater currently on screen.
struct ActiveFloaterStoryState: Equatable {
    let campaign: CampaignModel
    let payload: CEPTriggerPayload
    let token: Int64
    let startedAtMs: Int64
    /// The screen the window opened on. Leaving it ends the campaign, so the name is
    /// captured at start rather than read live. `nil` means it opened before any screen
    /// was ever set, and is therefore not screen-scoped.
    let screenName: String?

    var config: FloaterStoryConfig { campaign.floaterStoryConfig! }

    /// Dashboard defaults layered with the CEP trigger's values, resolved once at start.
    /// Every `{{ token }}` in the window and in the stories reads through this.
    var variableContext: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }
}

@MainActor
final class FloaterStoryOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveFloaterStoryState?
    @Published private(set) var dragFraction: FloaterFraction?
    /// `true` while the story is open. The window stays mounted underneath — the viewer
    /// is a cover over it, not a replacement for it — but the auto-dismiss clock stops.
    @Published private(set) var storyOpen = false
    /// `true` once dismissal has begun but the exit animation is still running. The view
    /// keeps rendering through this so the window can animate out; every other caller
    /// should treat the campaign as gone (see `isShowing`).
    @Published private(set) var closing = false
    /// The window's current on-screen frame in `.global` space, kept in sync by the
    /// view — `nil` whenever nothing is showing. Same purpose as the PiP's `activeRect`:
    /// an RN/UIKit host's `hitTest` has to tell a touch on this small, draggable window
    /// apart from empty SwiftUI space elsewhere.
    @Published var activeRect: CGRect?

    private var obscured = false
    private var tokenCounter: Int64 = 0
    private var moveCount = 0
    private var openCount = 0
    private var storyMs: Int64 = 0
    private var storyStartedAtMs: Int64?
    private var everOpened = false
    private var completed = false
    private var visible = false

    private var autoDismissTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private(set) var lastStartFailureReason: String?

    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    private let onDismissed: (ActiveFloaterStoryState, FloaterDismissReason, FloaterMetrics) -> Void
    private let onCompleted: (ActiveFloaterStoryState) -> Void
    private let onStepViewed: (ActiveFloaterStoryState) -> Void
    private let onStepDismissed: (ActiveFloaterStoryState) -> Void
    private let onVisible: (ActiveFloaterStoryState) -> Void

    init(
        onDismissed: @escaping (ActiveFloaterStoryState, FloaterDismissReason, FloaterMetrics) -> Void,
        onCompleted: @escaping (ActiveFloaterStoryState) -> Void,
        onStepViewed: @escaping (ActiveFloaterStoryState) -> Void,
        onStepDismissed: @escaping (ActiveFloaterStoryState) -> Void,
        onVisible: @escaping (ActiveFloaterStoryState) -> Void
    ) {
        self.onDismissed = onDismissed
        self.onCompleted = onCompleted
        self.onStepViewed = onStepViewed
        self.onStepDismissed = onStepDismissed
        self.onVisible = onVisible
    }

    /// Whether a story floater is live. `false` the moment dismissal starts, even though
    /// `state` lingers for the exit animation.
    var isShowing: Bool { state != nil && !closing }

    /// Starts a story floater. Returns `false` when preconditions fail or one is already
    /// showing — one at a time, like the PiP and survey.
    @discardableResult
    func start(_ campaign: CampaignModel, payload: CEPTriggerPayload, screenName: String?) -> Bool {
        lastStartFailureReason = nil
        guard campaign.campaignType == "floater", campaign.floaterStoryConfig != nil else {
            lastStartFailureReason = "campaign is not a parsed story floater"
            return false
        }
        // One still animating out has already ended. Cut its exit short rather than
        // refusing the new campaign — a trigger landing inside that window would
        // otherwise be dropped for a reason no one could see.
        if closing { finishDismiss() }
        guard state == nil else {
            lastStartFailureReason = "another story floater is already on screen"
            return false
        }

        tokenCounter += 1
        state = ActiveFloaterStoryState(
            campaign: campaign,
            payload: payload,
            token: tokenCounter,
            startedAtMs: now(),
            screenName: screenName
        )
        dragFraction = nil
        storyOpen = false
        closing = false
        obscured = false
        visible = false
        moveCount = 0
        openCount = 0
        storyMs = 0
        storyStartedAtMs = nil
        everOpened = false
        completed = false
        return true
    }

    /// The window painted. Idempotent — only the first call counts. `token` identifies
    /// the showing that reported it, so a callback arriving after its campaign ended
    /// cannot mark the next one visible.
    func markVisible(token: Int64) {
        guard let active = state, active.token == token, !visible else { return }
        visible = true
        restartAutoDismiss()
        onVisible(active)
    }

    /// The user dragged the window somewhere new.
    func moveTo(_ fraction: FloaterFraction) {
        guard state != nil else { return }
        dragFraction = fraction.clamped()
        moveCount += 1
    }

    /// The user tapped the window and the story is opening.
    func openStory() {
        guard let active = state, !closing, !storyOpen else { return }
        storyOpen = true
        openCount += 1
        everOpened = true
        storyStartedAtMs = now()
        // A user watching a story is engaged; taking the campaign away underneath them
        // would be hostile. The clock restarts when they come back.
        autoDismissTask?.cancel()
        autoDismissTask = nil
        onStepViewed(active)
    }

    /// The story finished or was closed. `.dismiss` ends the whole showing here; the
    /// default returns to the window so the story can be watched again.
    func closeStory() {
        guard let active = state, storyOpen else { return }
        storyOpen = false
        accumulateStoryMs()
        if active.config.behavior.onStoryEnd == .dismiss {
            dismiss(.ctaTaken)
            return
        }
        onStepDismissed(active)
        restartAutoDismiss()
    }

    /// Marks the window covered by a modal. The campaign lives; its timeout does not run
    /// down underneath something the user is looking at instead.
    func setObscured(_ value: Bool) {
        guard state != nil, !closing, obscured != value else { return }
        obscured = value
        if value {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        } else {
            restartAutoDismiss()
        }
    }

    /// The app went to the background, or came back. The window is scoped to a screen the
    /// user is no longer looking at, so its timeout must not run down while they are
    /// elsewhere.
    func setAppForegrounded(_ foregrounded: Bool) {
        guard state != nil else { return }
        if foregrounded {
            restartAutoDismiss()
        } else {
            autoDismissTask?.cancel()
            autoDismissTask = nil
        }
    }

    /// The host reported a new current screen. A floater belongs to the exact screen it
    /// opened on — see `FloaterOrchestrator.onScreenChanged` for why this deliberately
    /// bypasses the shared `targetScreenNames` helper.
    func onScreenChanged(_ screenName: String) {
        guard let active = state, let ownScreen = active.screenName, ownScreen != screenName
        else { return }
        dismiss(.screenExit)
    }

    /// Ends the showing, running the exit animation first when there is one. Idempotent.
    func dismiss(_ reason: FloaterDismissReason) {
        guard let active = state, !closing else { return }

        autoDismissTask?.cancel()
        autoDismissTask = nil
        // Closes out any open story span first, so `engagedMs` is whole when the snapshot
        // below reads it.
        accumulateStoryMs()

        // Watching the story is what this format asks for, so that — and only that —
        // completes a showing. Evaluated HERE and nowhere else, so a showing completes
        // exactly once, at its end, rather than retiring the campaign while its window is
        // still on screen.
        if everOpened { complete() }

        // A showing that never painted reports nothing at all — no Viewed, so no
        // Dismissed either. The terminal event is the denominator for every floater rate
        // on the backend.
        if visible { onDismissed(active, reason, metricsSnapshot()) }

        let exit = active.config.window.exitAnimation
        guard exit.type != .none, !obscured else {
            finishDismiss()
            return
        }
        closing = true
        exitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(exit.durationMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.finishDismiss()
        }
    }

    /// Marks the showing as having achieved its goal. At most once per showing.
    func complete() {
        guard let active = state, !closing, !completed else { return }
        completed = true
        onCompleted(active)
    }

    /// The corner the window is resting in, for the `last_position` property. Derived
    /// from the drag fraction rather than tracked separately, so the reported corner can
    /// never disagree with where the window actually is.
    func restingCorner() -> FloaterCorner {
        guard let config = state?.config else { return .bottomRight }
        guard let drag = dragFraction else { return config.window.position }
        switch (drag.y >= 0.5, drag.x >= 0.5) {
        case (true, true): return .bottomRight
        case (true, false): return .bottomLeft
        case (false, true): return .topRight
        case (false, false): return .topLeft
        }
    }

    /// Immediate, synchronous teardown for host shutdown / test reset.
    func dispose() {
        autoDismissTask?.cancel()
        exitTask?.cancel()
        autoDismissTask = nil
        exitTask = nil
        finishDismiss()
    }

    private func finishDismiss() {
        exitTask?.cancel()
        exitTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        state = nil
        dragFraction = nil
        activeRect = nil
        storyOpen = false
        closing = false
        obscured = false
        visible = false
        storyMs = 0
        storyStartedAtMs = nil
        everOpened = false
        completed = false
    }

    private func restartAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard visible, !storyOpen, !obscured,
              let afterMs = state?.config.behavior.autoDismissAfterMs
        else { return }
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(.autoTimeout)
        }
    }

    private func metricsSnapshot() -> FloaterMetrics {
        FloaterMetrics(
            moves: moveCount,
            // "Expanded" in the floater schema means "the campaign's own content was
            // opened" — for a PiP that is full screen, and here it is the story. One
            // schema, so the dashboard's floater analytics read both subtypes.
            expands: openCount,
            engagedMs: currentStoryMs(),
            lastPosition: restingCorner().wire
        )
    }

    private func currentStoryMs() -> Int64 {
        guard let startedAt = storyStartedAtMs else { return storyMs }
        return storyMs + (now() - startedAt)
    }

    private func accumulateStoryMs() {
        guard let startedAt = storyStartedAtMs else { return }
        storyMs += now() - startedAt
        storyStartedAtMs = nil
    }
}
