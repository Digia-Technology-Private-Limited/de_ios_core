import AVFoundation
@_implementationOnly import Lottie
import Foundation
import Combine
import UIKit

// Ported from Flutter's `pip_orchestrator.dart` / Android's `FloaterOrchestrator.kt` —
// method names and semantics mirror both 1:1 so all three SDKs stay in parity. Owns
// the active floater — at most one at a time — and, critically, its media player.
//
// **Why the player lives here and not in the view.** The floater grows from a small
// corner window into full screen. If the `AVPlayer` were created by the renderer
// (`@State`, as `NudgeVideoView` does), that transition would risk disposing and
// rebuilding it across a collapsed↔expanded view-identity change, restarting
// playback. Hoisting it to the orchestrator means the view subtree may redraw freely
// while the media surface is created once and released once — the "never
// re-parented" rule the whole design rests on.
//
// This orchestrator deliberately does **not** take a display lock while collapsed: a
// floater can sit on a screen for minutes, and blocking every other campaign for
// that long is not acceptable. It behaves modally only while expanded (enforced by
// the caller, not this class — see `SDKInstance.isModalCampaignActive()`).

enum FloaterSurface: Equatable {
    case collapsed, expanded
}

/// Why a floater ended. Extends the shared dismiss vocabulary with the reasons only a
/// screen-scoped floating surface can have. The iOS SDK has no existing
/// `DismissReason` enum to conform to (nudge/guide/survey all dismiss with no reason
/// parameter) — this is net-new, matching Android's/Flutter's `FloaterDismissReason`.
enum FloaterDismissReason: Equatable {
    case userClose
    /// The user took an action from the expanded content. Distinct from `.userClose`:
    /// one is "get this off my screen", the other is the campaign doing its job.
    case ctaTaken
    case screenExit
    case autoTimeout
    case mediaEnd
    case invalidated
    case sessionEnd
    case superseded
    case hostTeardown

    var wire: String {
        switch self {
        case .userClose: return "user_close"
        case .ctaTaken: return "cta_taken"
        case .screenExit: return "screen_exit"
        case .autoTimeout: return "auto_timeout"
        case .mediaEnd: return "media_end"
        case .invalidated: return "invalidated"
        case .sessionEnd: return "session_end"
        case .superseded: return "superseded"
        case .hostTeardown: return "host_teardown"
        }
    }
}

struct FloaterMetrics: Equatable {
    let moves: Int
    let expands: Int
    let engagedMs: Int64
    let lastPosition: String
}

/// A drag position as a fraction of the free space in each axis (0 = left/top,
/// 1 = right/bottom).
struct FloaterFraction: Equatable {
    var x: CGFloat
    var y: CGFloat

    func clamped() -> FloaterFraction {
        FloaterFraction(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

/// The floater currently on screen.
struct ActiveFloaterState: Equatable {
    let campaign: CampaignModel
    let payload: CEPTriggerPayload
    let token: Int64
    let startedAtMs: Int64
    /// The screen the floater was shown on. Leaving it ends the campaign, so the name
    /// is captured at start rather than read live. `nil` means the floater opened
    /// before any screen was ever set, and is therefore not screen-scoped.
    let screenName: String?

    var config: FloaterConfig { campaign.floaterConfig! }

    /// Dashboard defaults layered with the CEP trigger's values, resolved once at
    /// start. Every `{{ token }}` in the content — and in the media URL — reads
    /// through this.
    var variableContext: VariableContext {
        buildVariableContext(schemas: config.variableSchemas, cepVars: payload.variables)
    }

    /// The media URL with variables resolved — per-user media is an authored
    /// feature, so the raw config value must never reach the player.
    var resolvedMediaUrl: String { interpolate(config.media.url, context: variableContext) }
}

@MainActor
final class FloaterOrchestrator: ObservableObject {
    @Published private(set) var state: ActiveFloaterState?
    @Published private(set) var surface: FloaterSurface = .collapsed
    @Published private(set) var dragFraction: FloaterFraction?
    @Published private(set) var muted = true
    /// `true` between `start` and the media being ready to paint — see `markVisible`.
    @Published private(set) var awaitingMedia = false
    /// `true` once dismissal has begun but the exit animation is still running. The
    /// view keeps rendering through this so the window can animate out; every other
    /// caller should treat the floater as gone (see `isShowing`).
    @Published private(set) var closing = false
    /// Mirrors the player's actual playing state, for the play/pause chrome button.
    @Published private(set) var isPlaying = false
    /// The floater's current on-screen frame in `.global` coordinate space, kept in
    /// sync by `FloaterSessionView` — `nil` whenever nothing is showing. Exposed via
    /// `Digia.floaterActiveRect` so an RN/UIKit host's `hitTest` can tell a touch on
    /// the (small, draggable-anywhere) collapsed window apart from empty SwiftUI
    /// space elsewhere, the same reason `DigiaDebugOverlayController.badgeFrame`
    /// exists for the debug bubble — see that type's doc for why a UIView's own
    /// `hitTest` can't distinguish the two on its own (SwiftUI is backed by a single
    /// hosting `UIView`). Not `private(set)`: the view is the writer here, same as
    /// `badgeFrame`.
    @Published var activeRect: CGRect?

    private(set) var player: AVPlayer?

    /// `true` while another campaign or a host modal covers the window. Playback
    /// pauses (if configured) and visible-time accounting stops, but the floater is
    /// not dismissed. Not currently driven by any caller in this build — `setObscured`
    /// exists for parity with the Flutter/Android source and is ready for a future
    /// modal-coverage signal.
    private var obscured = false
    private var mediaEnded = false
    private var tokenCounter: Int64 = 0
    private var moveCount = 0
    private var expandCount = 0
    private var expandedMs: Int64 = 0
    private var expandedStartedAtMs: Int64?
    /// Whether full screen was ever on screen — including a campaign that opened
    /// there. Distinct from `expandCount`, which counts only *user* expansions and so
    /// is 0 for a `startExpanded` showing.
    private var everExpanded = false
    private var completed = false

    private var autoDismissTask: Task<Void, Never>?
    private var exitTask: Task<Void, Never>?
    private var mediaReadyTask: Task<Void, Never>?
    private(set) var lastStartFailureReason: String?
    private var statusObservation: NSKeyValueObservation?
    /// `addObserver(forName:object:queue:using:)` returns an opaque token that is
    /// *not* removable via `removeObserver(self, ...)` — that selector-based overload
    /// only matches observers registered the old way. The token itself must be
    /// stored and passed back to `removeObserver(_:)`, matching `NudgeVideoView`'s
    /// identical `loopObserver` pattern.
    private var endTimeObserverToken: NSObjectProtocol?

    /// Overridable so tests can drive playback without a real `AVPlayer`/network.
    var playerFactory: ((String) -> AVPlayer)?
    var now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }

    private static let mediaTimeoutMs: Int64 = 10_000

    private let onDismissed: (ActiveFloaterState, FloaterDismissReason, FloaterMetrics) -> Void
    private let onCompleted: (ActiveFloaterState) -> Void
    private let onStepViewed: (ActiveFloaterState) -> Void
    private let onStepDismissed: (ActiveFloaterState) -> Void
    private let onVisible: (ActiveFloaterState) -> Void

    init(
        onDismissed: @escaping (ActiveFloaterState, FloaterDismissReason, FloaterMetrics) -> Void,
        onCompleted: @escaping (ActiveFloaterState) -> Void,
        onStepViewed: @escaping (ActiveFloaterState) -> Void,
        onStepDismissed: @escaping (ActiveFloaterState) -> Void,
        onVisible: @escaping (ActiveFloaterState) -> Void
    ) {
        self.onDismissed = onDismissed
        self.onCompleted = onCompleted
        self.onStepViewed = onStepViewed
        self.onStepDismissed = onStepDismissed
        self.onVisible = onVisible
    }

    /// Whether a floater is live. `false` the moment dismissal starts, even though
    /// `state` lingers for the exit animation. Callers asking this want "is a
    /// campaign running", and a window fading out is not — only the view cares about
    /// the difference.
    var isShowing: Bool { state != nil && !closing }

    /// Starts a floater. Returns `false` when preconditions fail or one is already
    /// showing — one at a time, like survey.
    @discardableResult
    func start(_ campaign: CampaignModel, payload: CEPTriggerPayload, screenName: String?) -> Bool {
        lastStartFailureReason = nil
        guard campaign.campaignType == "floater", campaign.floaterConfig != nil else {
            lastStartFailureReason = "campaign is not a parsed floater"
            return false
        }
        // A floater still animating out has already ended. Cut its exit short rather
        // than refusing the new campaign — otherwise a trigger landing inside that
        // window would be dropped for a reason no one could see.
        if closing { finishDismiss() }
        if state != nil {
            lastStartFailureReason = "another floater is active"
            return false
        }

        tokenCounter += 1
        let nowMs = now()
        let active = ActiveFloaterState(
            campaign: campaign, payload: payload, token: tokenCounter,
            startedAtMs: nowMs, screenName: screenName
        )
        let startsExpanded = active.config.behavior.startExpanded
        state = active
        surface = startsExpanded ? .expanded : .collapsed
        dragFraction = nil
        muted = active.config.media.startMuted
        obscured = false
        closing = false
        mediaEnded = false
        moveCount = 0
        // A campaign that opens full screen did not have the user expand it, so the
        // count starts at zero either way.
        expandCount = 0
        expandedMs = 0
        expandedStartedAtMs = startsExpanded ? nowMs : nil
        everExpanded = startsExpanded
        completed = false
        // Assume we wait; prepareMedia releases it as soon as the media is ready, or
        // immediately when there is nothing to load. Set beforehand so a
        // synchronously-resolving provider (a test factory) cannot be overwritten
        // back to false afterwards.
        awaitingMedia = true
        prepareMedia(active)
        // prepareMedia can give up synchronously — an unusable URL. The campaign
        // never ran and there will be no terminal event, so report the drop rather
        // than claim acceptance and leave the CEP holding its in-app slot forever.
        let accepted = state?.token == active.token
        if !accepted, lastStartFailureReason == nil {
            lastStartFailureReason = "media was abandoned synchronously"
        }
        return accepted
    }

    /// The window is on screen. Idempotent — only the first call counts. `token`
    /// identifies the showing that requested the load; a slow response arriving
    /// after its campaign ended would otherwise reveal whichever floater is on
    /// screen now, before *its* media was ready.
    func markVisible(token: Int64) {
        guard let active = state, active.token == token else { return }
        mediaReadyTask?.cancel()
        mediaReadyTask = nil
        guard awaitingMedia else { return }
        awaitingMedia = false
        restartAutoDismiss()
        onVisible(active)
    }

    /// The media could not be loaded, so the campaign never runs. There is nothing to
    /// degrade to: the media *is* the floater, and a bordered empty box floating over
    /// the host app is worse for the user than no campaign at all. Teardown is
    /// silent — the window never painted, so there was no impression, no frequency
    /// cost and no terminal event, exactly as for a floater dismissed mid-load.
    func abandonMedia(token: Int64, reason: String) {
        guard let active = state, active.token == token, awaitingMedia else { return }
        DigiaLog.warning(
            "floater campaign '\(active.campaign.campaignKey)' dropped: media could not be loaded (\(reason))."
        )
        lastStartFailureReason = "media could not be loaded: \(reason)"
        finishDismiss()
    }

    /// Loads the campaign's media, revealing the window only once there is something
    /// to draw. Every kind waits — the empty-box-then-pop problem is not video's
    /// alone; a remote image or Lottie arrives just as late.
    private func prepareMedia(_ active: ActiveFloaterState) {
        let config = active.config
        let token = active.token
        let url = active.resolvedMediaUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // A URL still carrying an unresolved `{{ token }}` would 404 loudly. With no
        // poster to fall back to there is nothing this campaign could show, so drop
        // it rather than float an empty frame.
        if url.isEmpty || url.contains("{{") {
            abandonMedia(token: token, reason: "no usable media url")
            return
        }

        mediaReadyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.mediaTimeoutMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.abandonMedia(token: token, reason: "timed out")
        }

        switch config.media.kind {
        case .video: preparePlayer(active, url: url, token: token)
        case .lottie: preloadLottie(url: url, token: token)
        case .image, .gif: preloadImage(url: url, token: token)
        }
    }

    private func preparePlayer(_ active: ActiveFloaterState, url: String, token: Int64) {
        guard let parsed = URL(string: url) else {
            abandonMedia(token: token, reason: "invalid media url")
            return
        }
        let config = active.config
        let p = playerFactory?(url) ?? AVPlayer(playerItem: AVPlayerItem(url: parsed))
        p.isMuted = muted
        p.volume = config.media.volume
        player = p

        // Attach the observer BEFORE anything else can race it — mirrors
        // NudgeVideoView's identical comment on the same ordering. KVO fires on an
        // arbitrary AVFoundation-owned thread, never guaranteed main, so every
        // mutation of this @MainActor-isolated orchestrator must hop explicitly.
        if let item = p.currentItem {
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.state?.token == token else { return }
                    switch item.status {
                    case .readyToPlay:
                        self.markVisible(token: token)
                        if config.media.autoplay { self.player?.play() }
                    case .failed:
                        self.abandonMedia(token: token, reason: "video failed to load")
                    default:
                        break
                    }
                }
            }
        }

        if config.media.loop {
            endTimeObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
            ) { [weak self] _ in
                guard let self, self.state?.token == token else { return }
                self.player?.seek(to: .zero)
                self.player?.play()
            }
        } else {
            endTimeObserverToken = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main
            ) { [weak self] _ in
                self?.onVideoEnded(token: token)
            }
        }

        p.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] rate in self?.isPlaying = rate > 0 }
            .store(in: &playingCancellables)
    }

    private var playingCancellables = Set<AnyCancellable>()

    private func preloadImage(url: String, token: Int64) {
        guard let parsed = URL(string: url) else {
            abandonMedia(token: token, reason: "invalid media url")
            return
        }
        // Plain URLSession, not SDWebImage's imperative loader — the latter's core
        // (non-SwiftUI) module isn't an explicit Package.swift product dependency
        // today, only SDWebImageSwiftUI is, and importing it unverified risks a
        // build break with no way to catch it before a device build. This means the
        // renderer's `WebImage` view re-fetches the URL instead of reading a
        // pre-warmed SDWebImage cache — a real but minor inefficiency (one extra
        // network round-trip), not a correctness issue, and worth revisiting once
        // this SDK has a working local build/test loop again.
        let task = URLSession.shared.dataTask(with: parsed) { [weak self] data, _, _ in
            Task { @MainActor in
                guard let self, self.state?.token == token else { return }
                if let data, UIImage(data: data) != nil {
                    self.markVisible(token: token)
                } else {
                    self.abandonMedia(token: token, reason: "image failed to load")
                }
            }
        }
        task.resume()
    }

    private func preloadLottie(url: String, token: Int64) {
        guard let parsed = URL(string: url) else {
            abandonMedia(token: token, reason: "invalid media url")
            return
        }
        Task { [weak self] in
            let loaded: Bool
            if parsed.pathExtension.lowercased() == "lottie" {
                loaded = (try? await DotLottieFile.loadedFrom(url: parsed)) != nil
            } else {
                loaded = await LottieAnimation.loadedFrom(url: parsed) != nil
            }
            guard let self, self.state?.token == token else { return }
            if loaded {
                self.markVisible(token: token)
            } else {
                self.abandonMedia(token: token, reason: "lottie failed to load")
            }
        }
    }

    /// Watches for playback reaching the end so `onMediaEnd` can act on it. `loop`
    /// media never reaches this (its own end-of-item observer just seeks back to
    /// zero) — which is also why `stopOn: experienceCompleted` fires on the first
    /// loop and not on every one.
    private func onVideoEnded(token: Int64) {
        guard let active = state, active.token == token, !mediaEnded else { return }
        mediaEnded = true
        // Non-looping media reaching its end completes the showing unconditionally —
        // even one that was never expanded. This mirrors an explicitly
        // flagged-but-unresolved product question already logged in
        // `ai_docs/pip-campaign-design.md` §5.4; ported as-is rather than "fixed"
        // independently here, since it is a product decision, not an iOS bug.
        complete()
        switch active.config.behavior.onMediaEnd {
        case .dismiss: dismiss(.mediaEnd)
        case .collapse: collapse()
        case .keepLastFrame, .loop: break
        }
    }

    /// (Re)arms the collapsed-state timeout. Called on start and on collapse;
    /// cancelled on expand and on dismiss.
    private func restartAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        guard let afterMs = state?.config.behavior.autoDismissAfterMs, surface != .expanded else { return }
        autoDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(afterMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss(.autoTimeout)
        }
    }

    func expand() {
        guard let active = state, !closing, surface != .expanded else { return }
        surface = .expanded
        expandCount += 1
        everExpanded = true
        expandedStartedAtMs = now()
        // The auto-dismiss timeout is a collapsed-state affordance: someone who
        // opened full screen is watching, and closing it under them would be rude.
        restartAutoDismiss()
        if active.config.expanded.unmuteOnExpand { setMuted(false) }
        onStepViewed(active)
    }

    func collapse() {
        guard let active = state, !closing, surface != .collapsed else { return }
        accumulateExpandedMs()
        surface = .collapsed
        restartAutoDismiss()
        onStepDismissed(active)
    }

    func setMuted(_ value: Bool) {
        guard let active = state, muted != value else { return }
        muted = value
        player?.volume = value ? 0 : active.config.media.volume
        player?.isMuted = value
    }

    /// Play/pause, for the optional playback-controls chrome button. No-op for
    /// non-playable media (image/GIF have no `player` to toggle).
    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
    }

    /// Records where the user left the window. Called once per drag release, not per
    /// pointer move.
    func moveTo(_ fraction: FloaterFraction) {
        guard state != nil else { return }
        dragFraction = fraction.clamped()
        moveCount += 1
    }

    /// Marks the window covered by a modal. Playback pauses (if configured); the
    /// campaign lives.
    func setObscured(_ value: Bool) {
        guard let active = state, !closing, obscured != value else { return }
        obscured = value
        if surface == .expanded {
            if value {
                accumulateExpandedMs()
            } else {
                expandedStartedAtMs = expandedStartedAtMs ?? now()
            }
        }
        // Only pause when the author asked for it. A campaign that opts out keeps
        // playing behind the modal, so audio and progress continue uninterrupted.
        guard active.config.behavior.pauseWhenObscured else { return }
        if value {
            player?.pause()
        } else if active.config.media.autoplay {
            player?.play()
        }
    }

    /// Pause/resume across app lifecycle. Never restarts from zero.
    func setAppForegrounded(_ foregrounded: Bool) {
        guard let active = state else { return }
        if !foregrounded {
            if surface == .expanded { accumulateExpandedMs() }
            player?.pause()
            return
        }
        guard !obscured else { return }
        if surface == .expanded { expandedStartedAtMs = expandedStartedAtMs ?? now() }
        if active.config.media.autoplay { player?.play() }
    }

    /// The corner the window is resting in, for the `last_position` property.
    /// Derived from the drag fraction rather than tracked separately, so the
    /// reported corner can never disagree with where the window actually is.
    func restingCorner() -> FloaterCorner {
        guard let config = state?.config else { return .bottomRight }
        guard let drag = dragFraction else { return config.collapsed.position }
        let right = drag.x >= 0.5
        let bottom = drag.y >= 0.5
        switch (bottom, right) {
        case (true, true): return .bottomRight
        case (true, false): return .bottomLeft
        case (false, true): return .topRight
        case (false, false): return .topLeft
        }
    }

    /// Ends the floater and releases the player. Idempotent. When the campaign has
    /// an exit animation, the state is kept alive for its duration so the window can
    /// animate out — `closing` is `true` throughout, and every mutator above is a
    /// no-op during it. Teardown then runs exactly as it does in the instant path.
    func dismiss(_ reason: FloaterDismissReason) {
        guard let active = state, !closing else { return }

        autoDismissTask?.cancel()
        autoDismissTask = nil
        // Closes out any open expanded span first, so `engagedMs` is whole when the
        // snapshot below reads it.
        accumulateExpandedMs()

        // Reaching full screen counts as completing: the user saw the content, which
        // is as much as a floater asks for. Evaluated HERE and nowhere else, so a
        // showing completes exactly once, at its end — a CTA tap does not complete
        // mid-showing and retire the campaign while it is still on screen.
        //
        // Keyed on `everExpanded` rather than `expandCount` so a campaign that opened
        // full screen still completes; the user never expanded it, but they saw
        // exactly the same thing.
        //
        // Completed is emitted before Dismissed so the terminal event stays last in
        // the stream.
        if everExpanded { complete() }

        // A showing that never painted reports nothing at all — no Viewed, so no
        // Dismissed either. Beyond the obvious (an unseen window is not an
        // impression), the terminal event is the denominator for every floater rate
        // on the backend, so a showing abandoned mid-load would arrive with
        // expands = 0 and quietly drag expand rate down.
        if !awaitingMedia {
            onDismissed(active, reason, metricsSnapshot())
        }

        let exit = active.config.collapsed.exitAnimation
        // Full screen fills the display, so animating it "out" to nothing looks like
        // a glitch — only the small window gets an exit.
        let animates = exit.type != .none && surface == .collapsed && !obscured
        guard animates else {
            finishDismiss()
            return
        }

        closing = true
        player?.pause()
        exitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(exit.durationMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.finishDismiss()
        }
    }

    private func finishDismiss() {
        exitTask?.cancel()
        exitTask = nil
        autoDismissTask?.cancel()
        autoDismissTask = nil
        // A floater dismissed before its first frame (screen exit during a slow
        // load) must not have a timer fire into the next showing.
        mediaReadyTask?.cancel()
        mediaReadyTask = nil
        awaitingMedia = false
        state = nil
        surface = .collapsed
        dragFraction = nil
        obscured = false
        closing = false
        mediaEnded = false
        expandedMs = 0
        expandedStartedAtMs = nil
        everExpanded = false
        completed = false
        isPlaying = false
        statusObservation?.invalidate()
        statusObservation = nil
        playingCancellables.removeAll()
        if let endTimeObserverToken { NotificationCenter.default.removeObserver(endTimeObserverToken) }
        endTimeObserverToken = nil
        player?.pause()
        player = nil
    }

    /// Called when the host reports a new current screen. A floater belongs to one
    /// screen, so being told the user is on a different one is the expected end of
    /// the campaign, not an error path. A floater that opened while no screen was
    /// ever set has a `nil` `screenName` and is therefore not screen-scoped — it
    /// survives navigation and ends by close, timeout, or media end instead.
    ///
    /// Deliberately **not** the shared `dismissForScreenChangeIfNeeded` helper
    /// nudge/survey/guide use: that checks the *current* `targetScreenNames` list
    /// against the new screen, while a floater is bound to the *exact* screen it
    /// appeared on — leaving it ends the campaign even if the new screen is also in
    /// `targetScreenNames`. Reusing the shared helper here would silently loosen
    /// that contract (matches the same deliberate divergence in Android's
    /// `DigiaInstance.handleScreenChanged`).
    func onScreenChanged(_ screenName: String) {
        guard let active = state, let ownScreen = active.screenName, ownScreen != screenName else { return }
        dismiss(.screenExit)
    }

    /// Marks the showing as having achieved its goal. At most once per showing — the
    /// CTA path and the expanded-then-dismissed path both route here, and whichever
    /// lands first wins.
    func complete() {
        guard let active = state, !closing, !completed else { return }
        completed = true
        onCompleted(active)
    }

    private func metricsSnapshot() -> FloaterMetrics {
        FloaterMetrics(
            moves: moveCount, expands: expandCount,
            engagedMs: currentExpandedMs(), lastPosition: restingCorner().wire
        )
    }

    private func currentExpandedMs() -> Int64 {
        guard let startedAt = expandedStartedAtMs else { return expandedMs }
        return expandedMs + (now() - startedAt)
    }

    private func accumulateExpandedMs() {
        guard let startedAt = expandedStartedAtMs else { return }
        expandedMs += now() - startedAt
        expandedStartedAtMs = nil
    }

    /// Immediate, synchronous teardown for host shutdown/test reset — does not wait
    /// for an exit-animation task the way `dismiss` can.
    func dispose() {
        autoDismissTask?.cancel()
        exitTask?.cancel()
        mediaReadyTask?.cancel()
        autoDismissTask = nil
        exitTask = nil
        mediaReadyTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        playingCancellables.removeAll()
        if let endTimeObserverToken { NotificationCenter.default.removeObserver(endTimeObserverToken) }
        endTimeObserverToken = nil
        player?.pause()
        player = nil
        state = nil
        surface = .collapsed
        dragFraction = nil
        awaitingMedia = false
        closing = false
        obscured = false
        mediaEnded = false
        expandedMs = 0
        expandedStartedAtMs = nil
        everExpanded = false
        completed = false
        isPlaying = false
    }
}
