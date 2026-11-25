import Foundation
import UIKit

/// The one open/load/ready watchdog for a game session, mirroring Android's
/// `OPEN_WATCHDOG_MS` acceptance window. The per-skin-`http` ceiling
/// (`GameBridge.httpWatchdogSeconds`, the `httpWatchdogs` dict) deliberately
/// stays where it is: one entry per in-flight call id with its own
/// started/timed-out bookkeeping, and it closes — never merely replies.
///
/// Two clocks, matching the behavior this centralizes (no timing change):
/// - Open wall: a single 15 s wall-clock window
///   (`PresentationCoordinator.defaultAcceptanceTimeout`, the same value the
///   presentation coordinator watches a direct game with) from the arm to
///   `ready`, across every phase and across background time. Direct entries
///   arm nothing here — the coordinator owns that window. Entry and rewards
///   opens have no coordinator presentation, so this is theirs. Armed at arm
///   time, so an open whose view is never sized is still watched; disarmed at
///   `ready`/`shown` only, never at the page commit.
/// - Phase budgets: 15 s to the page commit, then 5 s to `ready`
///   (`GameBridge.loadTimeoutSeconds` / `readyTimeoutSeconds`), counted in
///   foreground time only. Backgrounding spends the running budget and parks
///   the timer; foregrounding re-arms with what is left, so repeated
///   backgrounding cannot keep a load alive forever.
///
/// Handles are cancellable, not fire-and-forget: the open wall keeps its
/// `DispatchWorkItem` (the existing wall seam) and the phase timer keeps its
/// `Task` (checked with `Task.isCancelled`), with the bridge generation token
/// (`GameBridge.beginLoading` / `cancelReadyTimer`) as belt-and-braces so a
/// stale timer from a superseded load is a no-op.
///
/// Replay signals: a prewarm adopt arms through `arm(request:)` (a held game
/// never armed, so the adopt is its first arm); a host recreation re-arms the
/// phase idempotently for the same request (replacing, never stacking, the
/// phase task); `failed`/`closed` cancel everything terminally.
@MainActor
final class GameOpenWatchdog {
    /// The replay/terminal signals the session funnels through `signal`.
    enum Event {
        /// The page committed: the ready phase starts with its own full budget.
        case pageCommitted
        /// `ready` arrived: disarm everything.
        case ready
        /// The game showed: disarm everything (same as `ready`).
        case shown
        /// The open failed: terminal, cancel everything.
        case failed
        /// The session closed: terminal, cancel everything.
        case closed
        /// The app left the foreground: spend the running budget, park the phase timer.
        case resignedActive
        /// The app returned: re-arm the phase with the remaining budget.
        case becameActive
        /// The host recreated its web view mid-load: re-arm the phase
        /// idempotently for the same request.
        case hostRecreated
    }

    /// Which phase timer the open is in: the reason the phase fire reports.
    /// `.loadTimeout` until the page commits, `.readyTimeout` after.
    private(set) var lastPhaseReason: GameFailureReason = .loadTimeout

    /// Fires when the 15 s wall elapses with the game still unready. The owner
    /// keeps its guards (`!didFinish`, `!isReady`, `!isHeld`): the watchdog
    /// only owns the schedule, never the settle decision.
    var onOpenTimeout: (() -> Void)?

    private weak var bridge: GameBridge?
    /// The open this wall arms for, `campaignKey#chanceId`. A re-arm for the
    /// same open never stacks a second wall; a different open supersedes.
    private var armedKey: String?
    private var openItem: DispatchWorkItem?
    private var phaseTask: Task<Void, Never>?
    /// Foreground seconds left in the current phase's budget; nil until the
    /// phase first arms.
    private var phaseRemaining: TimeInterval?
    /// Uptime when the running phase timer armed; nil while none runs.
    private var phaseArmedAt: TimeInterval?
    /// Whether the page committed (ready phase) or not (load phase).
    private var committed = false
    /// Set by `failed`/`closed`: every later arm or signal is a no-op.
    private var terminal = false

    init(bridge: GameBridge) {
        self.bridge = bridge
    }

    /// The identity one wall arms for.
    static func key(for request: GameOpenRequest) -> String {
        "\(request.campaignKey)#\(request.chanceId)"
    }

    /// Arms the open for `request`: the single 15 s wall (unless a direct
    /// entry, whose window the coordinator owns) plus the current phase timer.
    /// The prewarm adopt path calls this after swapping in the tap's request:
    /// a held game never armed, so the adopt is its first arm. A re-arm for
    /// the same open keeps the one wall and replaces the phase task with a
    /// fresh bridge generation, so a stale timer can never fire for it.
    func arm(request: GameOpenRequest) {
        guard !terminal else { return }
        let key = Self.key(for: request)
        if let armedKey, armedKey != key {
            // A different open supersedes: drop this wall before arming its own.
            openItem?.cancel()
            openItem = nil
            self.armedKey = nil
        }
        if armedKey == nil { armedKey = key }
        armOpenWall(request: request)
        armPhase()
    }

    /// Funnels one session signal into the schedule. `failed` and `closed`
    /// are terminal: they cancel everything and disarm future arms.
    func signal(_ event: Event) {
        switch event {
        case .pageCommitted:
            guard !terminal else { return }
            committed = true
            // The ready phase starts with its own full budget.
            phaseRemaining = nil
            phaseArmedAt = nil
            armPhase()
        case .ready, .shown:
            // Disarm at ready/shown only — never at the commit.
            cancelTimers()
        case .failed, .closed:
            cancel()
        case .resignedActive:
            guard !terminal, bridge?.state == .loading else { return }
            spendPhaseBudget()
            phaseTask?.cancel()
            phaseTask = nil
            bridge?.cancelReadyTimer()
        case .becameActive, .hostRecreated:
            guard !terminal else { return }
            armPhase()
        }
    }

    /// Terminal cancel: drops the wall and the phase timer, spends nothing,
    /// and invalidates any in-flight phase timer via the bridge generation.
    /// `failed` and `closed` both funnel here.
    func cancel() {
        terminal = true
        cancelTimers()
        bridge?.cancelReadyTimer()
    }

    // MARK: - Scheduling

    /// The single 15 s wall for a non-direct open. Wall clock, so it runs
    /// across background time; the fire's owner-side guards decide.
    private func armOpenWall(request: GameOpenRequest) {
        guard request.entry != GamificationEntryKind.direct.rawValue else { return }
        guard openItem == nil else { return }
        let seconds = PresentationCoordinator.defaultAcceptanceTimeout
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.openItem = nil
                self.onOpenTimeout?()
            }
        }
        openItem = item
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + seconds, execute: item)
    }

    /// Arms the timer for the phase the load is in: 15 s to the page commit,
    /// then 5 s to `ready`. Foreground only; a re-arm replaces the running
    /// task with a fresh bridge generation, so an earlier timer is stale.
    /// Runs only while loading and in the foreground.
    private func armPhase() {
        guard !terminal,
              let bridge,
              bridge.state == .loading,
              UIApplication.shared.applicationState == .active
        else { return }
        spendPhaseBudget()
        let seconds = phaseRemaining
            ?? (committed ? GameBridge.readyTimeoutSeconds : GameBridge.loadTimeoutSeconds)
        phaseRemaining = seconds
        phaseArmedAt = MonotonicClock.nowSeconds()
        lastPhaseReason = committed ? .readyTimeout : .loadTimeout
        let reason = lastPhaseReason
        let generation = bridge.beginLoading()
        phaseTask?.cancel()
        phaseTask = Task { @MainActor [weak self, weak bridge] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard let self, let bridge else { return }
            self.phaseTask = nil
            if reason == .readyTimeout {
                bridge.readyTimeoutFired(generation: generation)
            } else {
                bridge.loadTimeoutFired(generation: generation)
            }
        }
    }

    /// Charges the running timer's foreground time to the phase budget.
    private func spendPhaseBudget() {
        guard let armedAt = phaseArmedAt, let remaining = phaseRemaining else { return }
        phaseRemaining = max(0, remaining - (MonotonicClock.nowSeconds() - armedAt))
        phaseArmedAt = nil
    }

    /// Drops the scheduled wall and phase timer without going terminal: the
    /// open is still live (ready/shown disarm), so future signals still apply.
    private func cancelTimers() {
        openItem?.cancel()
        openItem = nil
        phaseTask?.cancel()
        phaseTask = nil
        phaseRemaining = nil
        phaseArmedAt = nil
    }
}
