import AVFoundation
import Foundation
import Network

// The story download window (T8): which players the viewer holds and which bytes it warms, as a
// pure function of the #157 rules, the slow-network rule (Decided), and the driver that carries a
// plan out through the pool and `MediaPrefetch`. Mirrors Android `StoryDownloadPlan`,
// `SlowNetwork` and `StoryPlanDriver`. iOS case names follow Swift lowerCamelCase.

/// The story download window as a pure function of the issue (#157) rules: given the stories,
/// the current index, whether its first frame has shown, and the network, it returns the player
/// and byte actions in serving order.
///
/// - `n` gets a player (`PoolPriority.onScreen`).
/// - If the first frame has not shown, nothing else: neighbour work waits for it.
/// - Slow network: first bytes of `n+1` only.
/// - `n` last: player `n-1` (`viewerPrev`), first bytes of `n-2`.
/// - Otherwise: player `n+1` (`viewerNext`), first bytes of `n+2`, player `n-1`, first bytes of `n-2`.
/// - Images get `wholeFile` instead of `firstBytes` (and instead of a player).
/// - A server without Range support gets `wholeFile`, only for `n±1`; deeper byte actions drop.
///
/// Out-of-range indices are dropped and an empty list (or an out-of-range `currentIndex`) plans
/// nothing, never a throw. The backward pair is player `n-1` + bytes `n-2`, as on Android.
internal enum StoryDownloadPlan {
    /// One story as the plan sees it: video (player + byte actions) or image
    /// (whole file). No JSON mapping is tested here (D4).
    internal struct Item: Sendable, Equatable {
        let isVideo: Bool
    }

    /// One download action for story `index`, in serving order.
    internal enum Action: Sendable, Equatable {
        /// Hold a pool player for `index` at `priority`.
        case player(index: Int, priority: PoolPriority)
        /// Warm the first bytes of `index` (a head start, not the whole file).
        case firstBytes(index: Int)
        /// Warm the whole file of `index`: images, or video on a server
        /// without Range.
        case wholeFile(index: Int)
    }

    static func plan(
        stories: [Item],
        currentIndex: Int,
        firstFrameShown: Bool,
        slowNetwork: Bool,
        rangeSupported: Bool = true
    ) -> [Action] {
        guard !stories.isEmpty, stories.indices.contains(currentIndex) else { return [] }
        var actions: [Action] = []
        actions.append(playerOrWholeFile(stories: stories, index: currentIndex, priority: .viewerPage))
        if !firstFrameShown { return actions }
        if slowNetwork {
            if let byte = byteOrWholeFile(
                stories: stories, index: currentIndex + 1,
                currentIndex: currentIndex, rangeSupported: rangeSupported
            ) {
                actions.append(byte)
            }
            return actions
        }
        if currentIndex == stories.index(before: stories.endIndex) {
            if currentIndex - 1 >= stories.startIndex {
                actions.append(playerOrWholeFile(
                    stories: stories, index: currentIndex - 1, priority: .viewerPrev
                ))
                if let byte = byteOrWholeFile(
                    stories: stories, index: currentIndex - 2,
                    currentIndex: currentIndex, rangeSupported: rangeSupported
                ) {
                    actions.append(byte)
                }
            }
            return actions
        }
        if stories.indices.contains(currentIndex + 1) {
            actions.append(playerOrWholeFile(
                stories: stories, index: currentIndex + 1, priority: .viewerNext
            ))
            if let byte = byteOrWholeFile(
                stories: stories, index: currentIndex + 2,
                currentIndex: currentIndex, rangeSupported: rangeSupported
            ) {
                actions.append(byte)
            }
        }
        if stories.indices.contains(currentIndex - 1) {
            actions.append(playerOrWholeFile(
                stories: stories, index: currentIndex - 1, priority: .viewerPrev
            ))
            if let byte = byteOrWholeFile(
                stories: stories, index: currentIndex - 2,
                currentIndex: currentIndex, rangeSupported: rangeSupported
            ) {
                actions.append(byte)
            }
        }
        return actions
    }

    private static func playerOrWholeFile(
        stories: [Item], index: Int, priority: PoolPriority
    ) -> Action {
        stories[index].isVideo ? .player(index: index, priority: priority) : .wholeFile(index: index)
    }

    private static func byteOrWholeFile(
        stories: [Item], index: Int, currentIndex: Int, rangeSupported: Bool
    ) -> Action? {
        guard stories.indices.contains(index) else { return nil }
        if !stories[index].isVideo { return .wholeFile(index: index) }
        if !rangeSupported {
            return (index == currentIndex - 1 || index == currentIndex + 1)
                ? .wholeFile(index: index)
                : nil
        }
        return .firstBytes(index: index)
    }
}


// MARK: - Slow-network signal (D10)

/// Below this downstream rate — kilobits per second — a warmed range counts as slow. Same value
/// and rationale as Android `SlowNetwork.SLOW_DOWNSTREAM_KBPS`: the plan's first-bytes warm is
/// 512 KiB (~4.2 Mb), so under ~1.5 Mbps one warm takes longer than the story step it
/// precedes and neighbour prefetch would contend with the current page's playback.
internal let slowDownstreamKbps: Double = 1_500

/// Where the viewer reads `slowNetwork` from. A closure-shaped protocol (not a
/// bare Bool) so tests inject a fixed value and the plan shapes stay
/// deterministic, while production reads the live path.
internal protocol SlowNetworkSource: Sendable {
    var isSlow: Bool { get }

    /// A first-bytes warm moved `bytes` in `elapsed` seconds. Sources that measure fold it
    /// into their verdict; the default ignores it.
    func noteWarm(bytes: Int, elapsed: TimeInterval)
}

extension SlowNetworkSource {
    func noteWarm(bytes: Int, elapsed: TimeInterval) {}
}

/// The one slow rule: slow = metered (expensive or constrained) OR the last measured warm
/// throughput below `slowDownstreamKbps`; an unknown signal votes nothing. Android adds the OS
/// link rate; iOS exposes none (platform limit), so that vote does not exist here. Kept free of
/// `NWPath` itself so tests pin the rule without constructing a path (`NWPath` has no public
/// initializer).
internal func slowNetworkFor(
    isExpensive: Bool,
    isConstrained: Bool,
    measuredKbps: Double? = nil
) -> Bool {
    if isExpensive || isConstrained { return true }
    if let measuredKbps, measuredKbps.isFinite, measuredKbps >= 0,
       measuredKbps < slowDownstreamKbps
    {
        return true
    }
    return false
}

/// Remembers the last warmed range as kilobits/second (bytes over wall time): the driver times
/// the `warmVideoBytes` call it already makes and notes the result here. One sample is only a
/// hint — a stale fast sample can never force the slow branch and a stale slow one clears on
/// the next warm. Mirrors Android `SlowNetworkThroughput`.
internal final class SlowNetworkThroughput: @unchecked Sendable {
    /// A warm that finished faster than this was served from the cache (512 KiB in under 20 ms
    /// is over 200 Mbps, more than any link), so it measures nothing: it must not vote, and it
    /// must not overwrite a real slow sample.
    static let minimumElapsed: TimeInterval = 0.02

    private let lock = NSLock()
    private var last: Double?

    var lastKbps: Double? { lock.withLock { last } }

    func note(bytes: Int, elapsed: TimeInterval) {
        guard bytes > 0, elapsed >= Self.minimumElapsed else { return }
        let kbps = Double(bytes) * 8 / 1_000 / elapsed
        lock.withLock { last = kbps }
    }
}

/// The live `SlowNetworkSource`: follows the device's network through `NWPathMonitor` and
/// reports slow while the path is expensive or constrained, or while the last measured warm
/// was slow. Starts satisfied-fast (not slow) until the first update and the first sample, so a
/// cold start never holds back neighbour work; an unreadable path degrades to not-slow, never
/// throws. One instance per process (`shared`), read by every viewer, so a
/// measurement taken by one story helps the next.
internal final class PathSlowNetworkSource: SlowNetworkSource, @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let throughput = SlowNetworkThroughput()
    private let lock = NSLock()
    private var expensive = false
    private var constrained = false

    init(monitor: NWPathMonitor = NWPathMonitor()) {
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.withLock {
                self.expensive = path.isExpensive
                self.constrained = path.isConstrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "tech.digia.engage.slow-network", qos: .utility))
    }

    var isSlow: Bool {
        let flags = lock.withLock { (expensive, constrained) }
        return slowNetworkFor(
            isExpensive: flags.0, isConstrained: flags.1, measuredKbps: throughput.lastKbps)
    }

    func noteWarm(bytes: Int, elapsed: TimeInterval) {
        throughput.note(bytes: bytes, elapsed: elapsed)
    }

    deinit { monitor.cancel() }
}

extension PathSlowNetworkSource {
    /// The process's one source: every viewer (inline, canvas, floater) judges the same network
    /// and shares one measured throughput.
    static let shared = PathSlowNetworkSource()
}

// MARK: - Driver

/// How many bytes the driver warms for a `firstBytes` action. Same value as Android
/// `STORY_FIRST_BYTES`.
let storyFirstBytes = 512 * 1_024

/// Carries a `StoryDownloadPlan` out: every `.player` action is a pool hold under the key the
/// page borrows under (so a swipe hands over the same player), and every byte action is a
/// `MediaPrefetch` warm.
///
/// Stateful: `update` diffs the new plan against what it holds. Holds the new plan no longer
/// names are given back, except those in `keepPlayersFor` (until the new page's first frame the
/// plan names only that page, yet the page just left and the one a back-swipe returns to keep
/// their players); a changed rank takes the new hold before letting go of the old one, so the
/// player is never freed in between. Neighbour players wait paused and muted, keeping their
/// playhead, so swiping back resumes (N9). Warms the plan no longer names are cancelled; bytes
/// already on disk stay. A refused borrow holds nothing: the page shows its still.
@MainActor
final class StoryPlanDriver {
    private struct Held {
        let key: String
        let player: AVPlayer
        let priority: PoolPriority
    }

    private let pool: VideoPlayerPool
    /// Warms a URL and answers the video bytes it delivered: 0 for a cancelled or failed warm.
    private let warm: @Sendable (String, MediaPrefetchKind, Int?) async -> Int
    /// Told how long each completed first-bytes warm took (bytes delivered, seconds): the measured
    /// slow vote. A cancelled or failed warm votes nothing.
    private let onWarm: @Sendable (Int, TimeInterval) -> Void
    private var tasks: [Int: Task<Void, Never>] = [:]
    private var warmed: Set<Int> = []
    private var held: [Int: Held] = [:]

    init(
        pool: VideoPlayerPool,
        warm: @escaping @Sendable (String, MediaPrefetchKind, Int?) async -> Int = { url, kind, bytes in
            await MediaPrefetch.warm(url, kind: kind, bytes: bytes)
        },
        onWarm: @escaping @Sendable (Int, TimeInterval) -> Void = { _, _ in }
    ) {
        self.pool = pool
        self.warm = warm
        self.onWarm = onWarm
    }

    func update(
        actions: [StoryDownloadPlan.Action],
        urlOf: (Int) -> String,
        isVideoOf: (Int) -> Bool,
        keyOf: (Int) -> String,
        keepPlayersFor keep: Set<Int> = []
    ) {
        updatePlayers(actions: actions, urlOf: urlOf, keyOf: keyOf, keep: keep)
        updateBytes(actions: actions, urlOf: urlOf, isVideoOf: isVideoOf)
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        warmed.removeAll()
        held.values.forEach { pool.giveBack(key: $0.key, player: $0.player, priority: $0.priority) }
        held.removeAll()
    }

    // MARK: Test seams

    var heldIndices: Set<Int> { Set(held.keys) }
    func heldPlayer(for index: Int) -> AVPlayer? { held[index]?.player }

    // MARK: Private

    private func updatePlayers(
        actions: [StoryDownloadPlan.Action], urlOf: (Int) -> String, keyOf: (Int) -> String, keep: Set<Int>
    ) {
        // A hold the pool took back (eviction, re-point) is gone already.
        for (index, entry) in held where pool.heldPlayer(for: entry.key) !== entry.player {
            held[index] = nil
        }
        var wanted: [(index: Int, priority: PoolPriority)] = []
        for action in actions {
            if case let .player(index, priority) = action { wanted.append((index, priority)) }
        }
        let wantedIndices = Set(wanted.map(\.index))
        for (index, entry) in held where !wantedIndices.contains(index) {
            if keep.contains(index) {
                // Kept for the page just left or the one a back-swipe returns to: it waits silently.
                prepareNeighbour(entry.player)
            } else {
                pool.giveBack(key: entry.key, player: entry.player, priority: entry.priority)
                held[index] = nil
            }
        }
        for want in wanted {
            let key = keyOf(want.index)
            let current = held[want.index]
            if let current, current.key == key, current.priority == want.priority {
                if want.priority != .viewerPage { prepareNeighbour(current.player) }
                continue
            }
            guard let url = mediaUsableURL(urlOf(want.index)),
                  let player = pool.borrow(key: key, url: url, priority: want.priority) else { continue }
            // The new hold first, so the player is never freed in between.
            if let current { pool.giveBack(key: current.key, player: current.player, priority: current.priority) }
            held[want.index] = Held(key: key, player: player, priority: want.priority)
            // The current page takes its own player over (sound, play); neighbours wait.
            if want.priority != .viewerPage { prepareNeighbour(player) }
        }
    }

    /// Paused and muted where it is: a fresh player waits at the start, the page just left keeps
    /// its playhead for a swipe back (N9).
    private func prepareNeighbour(_ player: AVPlayer) {
        player.pause()
        player.isMuted = true
    }

    private func updateBytes(actions: [StoryDownloadPlan.Action], urlOf: (Int) -> String, isVideoOf: (Int) -> Bool) {
        var wanted: [Int: (url: String, kind: MediaPrefetchKind, bytes: Int?)] = [:]
        for action in actions {
            switch action {
            case let .firstBytes(index):
                wanted[index] = (urlOf(index), .video, storyFirstBytes)
            case let .wholeFile(index):
                wanted[index] = isVideoOf(index) ? (urlOf(index), .video, nil) : (urlOf(index), .image, nil)
            case .player:
                break
            }
        }
        warmed.formIntersection(wanted.keys)
        for index in Set(tasks.keys).subtracting(wanted.keys) {
            tasks.removeValue(forKey: index)?.cancel()
        }
        for (index, work) in wanted where !warmed.contains(index) && tasks[index] == nil {
            let warm = warm
            let onWarm = onWarm
            tasks[index] = Task { [weak self] in
                let began = ProcessInfo.processInfo.systemUptime
                let delivered = await warm(work.url, work.kind, work.bytes)
                // A warm the plan moved on from measured nothing: no vote. One that failed delivered
                // 0 bytes, which `SlowNetworkThroughput.note` does not count.
                guard !Task.isCancelled else { return }
                if work.kind == .video, work.bytes != nil {
                    onWarm(delivered, ProcessInfo.processInfo.systemUptime - began)
                }
                self?.tasks[index] = nil
                self?.warmed.insert(index)
            }
        }
    }
}
