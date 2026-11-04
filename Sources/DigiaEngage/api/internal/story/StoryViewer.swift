import AVFoundation
import Foundation
import SwiftUI

// MARK: - Viewer session

/// Posted (async, after the disappear pass and its pool `giveBack`s finish) when a story viewer
/// fully closes. The rail remounts its videos on this — never on the overlay flag flip, which
/// fires while the viewer is still tearing down and sharing the handed-over holder.
extension Notification.Name {
    static let storyViewerDidClose = Notification.Name("tech.digia.engage.storyViewerDidClose")
}

/// What the viewer reports. The entry points translate these into their own analytics: the
/// classic story events for inline, canvas interactions for canvas and floater.
/// Main-actor isolated: sessions call it from the UI thread, like every other report path.
@MainActor
protocol StoryViewerReporter {
    func onCompleted(total: Int, timeToCompleteMs: Int64)
    func onDismissed(index: Int)
}

/// One viewer session (T10): one mute state per session, reset to the campaign default on every
/// open. Keyed on the opening (stories, start index, handoff key) — never on the current index:
/// swiping runs inside the session (`currentIndex` is its own state), so mute, progress and the
/// completion guard survive navigation. Only a reopen (dismiss → open) mints a fresh session.
///
/// `openToken` names the session: two opens never share mute/progress even for identical input.
/// Mirrors Android `StoryViewerSession`.
@MainActor
final class StoryViewerSession: ObservableObject {
    let stories: [StoryItemConfig]
    let startIndex: Int
    /// The rail's transfer token when a playing thumbnail was tapped; else nil.
    let handoffKey: String?
    let restartOnCompleted: Bool
    let reporter: StoryViewerReporter
    /// Closes the host (dialog, window, hero); the viewer reports first.
    let onDismiss: @MainActor @Sendable () -> Void
    /// Unique per open: the session key. Never derived from content.
    let openToken = UUID()

    @Published var currentIndex: Int
    @Published var muted: Bool
    /// Remounts the current page (a replay restarts its video from 0).
    @Published var replayTick = 0

    private var completedReported = false
    private let openedAt = Date()

    /// Whether the end of the story was reported: closing after it is not a dismissal.
    var isCompleted: Bool { completedReported }

    init(
        stories: [StoryItemConfig],
        startIndex: Int,
        handoffKey: String?,
        restartOnCompleted: Bool,
        startMuted: Bool,
        reporter: StoryViewerReporter,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        self.stories = stories
        let clamped = min(max(startIndex, 0), max(stories.count - 1, 0))
        self.startIndex = clamped
        self.handoffKey = handoffKey
        self.restartOnCompleted = restartOnCompleted
        self.reporter = reporter
        self.onDismiss = onDismiss
        self.currentIndex = clamped
        self.muted = startMuted
    }

    /// The key the page at `index` borrows under: the rail's handoff token wins for the start
    /// page (the rail already namespaced it, so it is reused as-is for a gapless handover);
    /// every other page is namespaced by `namespace`.
    func pageKey(index: Int, namespace: String? = nil) -> String {
        if index == currentIndex, let handoffKey, index == startIndex {
            return handoffKey
        }
        return storyPoolKey(namespace: namespace, index: index)
    }

    func showPage(index: Int) {
        currentIndex = stories.isEmpty ? 0 : min(max(index, 0), stories.count - 1)
    }

    func advance() {
        guard !stories.isEmpty else {
            onDismiss()
            return
        }
        if currentIndex < stories.count - 1 {
            showPage(index: currentIndex + 1)
            return
        }
        // Reaching the end is the completion — at most once per showing, so a looping story
        // does not report a completion per lap.
        if !completedReported {
            completedReported = true
            reporter.onCompleted(
                total: stories.count,
                timeToCompleteMs: Int64(Date().timeIntervalSince(openedAt) * 1_000)
            )
        }
        if restartOnCompleted {
            showPage(index: 0)
        } else {
            onDismiss()
        }
    }

    func goBack() {
        if currentIndex > 0 {
            showPage(index: currentIndex - 1)
        } else {
            // Reset the first story: the viewer re-shows the step and restarts its media.
            replayTick &+= 1
        }
    }

    /// Closing before the end is a dismissal; closing *at* the end is the completion already
    /// reported by `advance`. Distinguishing them is what makes drop-off measurable.
    func dismiss() {
        if !completedReported {
            reporter.onDismissed(index: currentIndex)
        }
        onDismiss()
    }
}

// MARK: - Page duration

/// Per-page time in seconds for images and fallbacks. A non-positive duration degrades forward
/// instead of stalling: the viewer skips the frame at once, never waits on a time that never
/// passes. Nil means "advance immediately". Mirrors Android `startCountdown`'s
/// `durationMs <= 0` arm.
func storyPageDurationSeconds(item: StoryItemConfig?, defaultMs: Int) -> Double? {
    let ms = item?.duration ?? defaultMs
    guard ms > 0 else { return nil }
    return Double(ms) / 1_000
}

// MARK: - Plan driver

/// How many bytes the driver warms for a `firstBytes` action: enough to reach the first ~2 s.
/// Same value as Android `STORY_FIRST_BYTES`.
let storyFirstBytes = 512 * 1_024

/// Executes the byte half of a `StoryDownloadPlan`: video first-bytes/whole-file warming and
/// image enqueueing, all through the `MediaPrefetch` protocol (lane H owns the implementation;
/// until then the no-op stub keeps every call site compiling and every test deterministic).
/// Player actions are pool leases when the caller wires `pool` + `keyOf` (R2-STORY): the
/// driver holds a lease for every `.player` action under the same campaign-namespaced keys
/// the pages borrow under, so a swipe hands over the same instance; callers that pass
/// neither keep today's byte-only behavior.
///
/// Stateful: `update` cancels in-flight work for indices the new plan no longer warms (bytes
/// already on disk stay there) and starts work for newly wanted indices; already-running
/// indices are left alone. Leases work the same way: indices that left the window are
/// released (their bytes stay on disk — only the holder goes back), still-wanted indices
/// keep their holder, and a re-obtain under a held key is the pool's share (same instance,
/// raised priority). Mirrors Android `StoryPlanDriver`.
final class StoryPlanDriver: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Int: Task<Void, Never>] = [:]
    /// Neighbour pool leases by story index: the `.player` half of the plan. The mounted page
    /// owns its own borrow; these keep the neighbours' holders warm.
    private var leases: [Int: PlayerLease] = [:]
    private let prefetch: any MediaPrefetch

    init(prefetch: any MediaPrefetch = NoopMediaPrefetch()) {
        self.prefetch = prefetch
    }

    func update(
        actions: [StoryDownloadPlan.Action],
        urlOf: @Sendable (Int) -> String,
        isVideoOf: @Sendable (Int) -> Bool,
        keyOf: (@Sendable (Int) -> String?)? = nil,
        pool: VideoPlayerPool? = nil
    ) {
        lock.withLock { tasks = tasks.filter { !$0.value.isCancelled } }
        var wanted: [Int: @Sendable () async -> Void] = [:]
        for action in actions {
            switch action {
            case let .firstBytes(index):
                let url = urlOf(index)
                wanted[index] = { [prefetch] in _ = await prefetch.warmVideoBytes(
                    url: url, lengthBytes: storyFirstBytes) }
            case let .wholeFile(index):
                let url = urlOf(index)
                if isVideoOf(index) {
                    wanted[index] = { [prefetch] in _ = await prefetch.warmWholeVideo(url: url) }
                } else {
                    prefetch.enqueueImage(url)
                }
            case .player:
                break
            }
        }
        let stale = lock.withLock { () -> [Task<Void, Never>] in
            let staleKeys = Set(tasks.keys).subtracting(wanted.keys)
            let staleTasks = staleKeys.compactMap { tasks.removeValue(forKey: $0) }
            return staleTasks
        }
        stale.forEach { $0.cancel() }
        for (index, work) in wanted {
            let exists = lock.withLock { tasks[index] != nil }
            guard !exists else { continue }
            let task = Task { [weak self] in
                await work()
                self?.remove(index: index)
            }
            lock.withLock { tasks[index] = task }
        }
        updatePlayerLeases(actions: actions, urlOf: urlOf, keyOf: keyOf, pool: pool)
    }

    /// Holds one lease per `.player` action in plan (serving) order, releasing the indices
    /// that left the window. A re-obtain under a held key is the pool's share — the fresh
    /// share is dropped and the committed holder stays. A changed holder (eviction,
    /// re-point) replaces the stale lease through the pool's identity check. A refused
    /// borrow holds nothing: the page renders its still (D3) and the driver moves on.
    /// Nil pool/keyOf keeps the byte-only behavior.
    private func updatePlayerLeases(
        actions: [StoryDownloadPlan.Action],
        urlOf: (Int) -> String,
        keyOf: ((Int) -> String?)?,
        pool: VideoPlayerPool?
    ) {
        guard let pool, let keyOf else { return }
        var wanted: [(index: Int, key: String, url: String, priority: PoolPriority)] = []
        for action in actions {
            guard case let .player(index, priority) = action else { continue }
            guard let key = keyOf(index) else { continue }
            wanted.append((index, key, urlOf(index), priority))
        }
        let wantedIndices = Set(wanted.map(\.index))
        let stale: [PlayerLease] = lock.withLock {
            var dropped: [PlayerLease] = []
            for index in leases.keys where !wantedIndices.contains(index) {
                if let lease = leases.removeValue(forKey: index) { dropped.append(lease) }
            }
            return dropped
        }
        stale.forEach { $0.release() }
        for want in wanted {
            guard let fresh = pool.obtainLease(
                key: want.key, url: want.url, priority: want.priority
            ) else { continue }
            lock.withLock {
                if let current = leases[want.index], current.player === fresh.player {
                    fresh.release()
                } else {
                    leases[want.index]?.release()
                    leases[want.index] = fresh
                }
            }
        }
    }

    private func remove(index: Int) {
        lock.withLock { tasks.removeValue(forKey: index) }
    }

    func cancelAll() {
        let running = lock.withLock { () -> [Task<Void, Never>] in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        running.forEach { $0.cancel() }
        let held: [PlayerLease] = lock.withLock {
            defer { leases.removeAll() }
            return Array(leases.values)
        }
        held.forEach { $0.release() }
    }
}
