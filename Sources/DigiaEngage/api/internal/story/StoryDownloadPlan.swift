import Foundation
import Network

// Mirrors Android's StoryDownloadPlan + the R-P3-02 deferral note: the issue's
// window rules as a pure function, and the slow-network signal the viewer
// passes in. iOS case names follow Swift lowerCamelCase instead of Android's
// UPPER_SNAKE_CASE (intended difference).

/// The story download window as a pure function of the issue (#157) rules:
/// given the stories, the current index, whether its first frame has shown,
/// and the network, it returns the player and byte actions in serving order.
/// The viewer recomputes on every swipe; the plan is the only thing that knows
/// the window shape, so "release players more than one away", "cancel downloads
/// outside the window" and "pause neighbour work until the first frame" all
/// fall out of diffing one plan against the next (players are the pool's job
/// via `MediaVideo(keepAliveKey)`; bytes are lane H/T12 `MediaPrefetch`'s).
///
/// Rules, exactly as specified:
/// - `n` gets a player (`PoolPriority.onScreen`).
/// - If the first frame has not shown, nothing else: neighbour work waits for it.
/// - Slow network: first bytes of `n+1` only.
/// - `n` last: player `n-1` (`PoolPriority.viewerPrev`), first bytes of `n-2`.
/// - Otherwise: player `n+1` (`PoolPriority.viewerNext`), first bytes of `n+2`,
///   player `n-1`, first bytes of `n-2`.
/// - Images get `Action.wholeFile` instead of `Action.firstBytes` (and instead
///   of a player: an image never needs a pool player).
/// - A server without Range support gets `Action.wholeFile`, only for `n±1`;
///   deeper byte actions are dropped.
///
/// Out-of-range indices are dropped and an empty list (or an out-of-range
/// `currentIndex`) plans nothing — never a throw.
///
/// NOTE on the middle case, same reading as Android: the issue text's middle
/// case reads "first bytes n−3" for the backward bytes while the last case
/// reads "first bytes n−2" for the same backward pair. Implemented as `n-2`
/// (symmetric: the backward pair is always player `n-1` + bytes `n-2`);
/// flagged for the owner. `prototypes/story-prefetch.PROTOTYPE.html` never
/// landed (re-checked `origin/main` 2026-11-02), so the swipe sequences in
/// tests come from these rules only.
///
/// Lane scope: zero-duration pages degrading forward and the session open token
/// (Android R-P3-03/04) are `StoryViewer` behaviours owned by lane F (T10
/// carries their tests); this file owns only the window shape plus the slow
/// signal below (D10).
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
        actions.append(playerOrWholeFile(stories: stories, index: currentIndex, priority: .onScreen))
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
/// throws. One instance per SDK (`SDKServices.slowNetworkSource`), shared by every viewer, so a
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
