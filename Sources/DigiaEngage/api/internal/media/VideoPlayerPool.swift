import AVFoundation
import Foundation

private let log = DigiaLogger()

// Ranking and sizes mirror Android's VideoPlayerPool (adapted there from Media3 1.9.0
// `DefaultPreloadManager`, Apache-2.0, notice kept on Android): the same four ranks in the same
// order. Case names follow Swift lowerCamelCase (intended difference).

/// Who a pooled player is held for, highest first. Each hold keeps its rank; a rank's stage
/// (`isStage1`) decides what happens at the live-player ceiling (OD-24): Stage 1 takes a Stage-2
/// holder's player, Stage 2 is refused and shows its still.
enum PoolPriority: Int, Sendable, Comparable {
    /// The story viewer's page on screen (Stage 1).
    case viewerPage = 0
    /// On screen and wants to play now (a floater, PIP, a canvas or nudge video, a carousel
    /// slide, a rail card). Stage 2.
    case onScreen = 1
    case viewerNext = 2
    case viewerPrev = 3

    static func < (lhs: PoolPriority, rhs: PoolPriority) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The story viewer's own pages: the one on screen and the neighbours the plan keeps ready.
    /// Never refused at the ceiling. Everything else is Stage 2.
    var isStage1: Bool { self == .viewerPage || self == .viewerNext || self == .viewerPrev }
}

/// Coarse device bucket; only the pool size reads it.
enum DeviceClass: Sendable, Equatable {
    case low
    case mid
    case high
}

/// Pool sizes per device class (Decided, OD-1). TODO(measure #157): placeholders until story
/// playback is profiled on low, mid and high devices.
func maxPoolPlayers(deviceClass: DeviceClass) -> Int {
    switch deviceClass {
    case .low: 2
    case .mid: 3
    case .high: 4
    }
}

/// What iOS is assumed to run at once (OD-24). iOS has no API for decoder limits; Apple DTS's only
/// stated figure is four concurrent players, and a paused player keeps its decoder.
let assumedDecoderSessions = 4

/// The live-player ceiling (OD-24): the most players, pooled and extra, alive at once. The
/// sessions this phone can count on, minus one left for the host app's own video, never below
/// the pool size.
func livePlayerCeiling(poolSize: Int, decoderSessions: Int = assumedDecoderSessions) -> Int {
    max(poolSize, decoderSessions - 1)
}

/// Classifies `ProcessInfo.physicalMemory`; thresholds are heuristics. Unknown (0) is the middle.
func deviceClassFor(physicalMemoryBytes: UInt64) -> DeviceClass {
    let gib: UInt64 = 1_024 * 1_024 * 1_024
    switch physicalMemoryBytes {
    case 0: return .mid
    case ..<(4 * gib): return .low
    case ..<(7 * gib): return .mid
    default: return .high
    }
}

/// The process-wide video players, leased by key (T4).
///
/// - The same key and URL hands over the same player with no new item, so the frame survives.
/// - Every `borrow` is one hold, taken when the surface mounts, and is paired with one
///   `giveBack`; the player is freed when the last hold lets go. Whether a borrow shares another
///   one's player is never decided up front (N6).
/// - A freed player is paused and kept with its item: a remount under the same key and URL gets
///   it back where it was (rotation, swipe back; N2). A finished showing, or the same file under
///   another key, restarts at 0. After `parkSeconds` free it lets go of its item, so the range
///   cache stops downloading a file nobody shows; a later borrow gets a new item and the surface
///   resumes at the old playhead (`takeResumeMs`).
/// - Each hold carries its own rank; a key ranks as the highest of its current holds, so its
///   rank drops when a higher hold goes (OD-10, R2-06a).
/// - A borrow of a held key with another URL re-points the player and tells every other holder
///   through its eviction observer: their holds end, they show their still and borrow again
///   when they next open (OD-10, R2-06c; no silent re-point, N5).
/// - Every player comes from the pool (OD-15): a `MediaVideo` with no natural key borrows under
///   a key of its own and `discard`s it when it leaves, so nothing is left idle for a dead node.
/// - A player whose item failed gets a new item on its next borrow: a borrow never inherits a
///   failure.
/// - Two stages (OD-24, replaces OD-1's rank gate). Stage 1 is the story viewer's own pages
///   (`PoolPriority.isStage1`), Stage 2 is everything else. Up to `maxPlayers` players are
///   pooled; above that every borrow gets an extra player until `ceiling` (live holders). At the
///   ceiling Stage 2 is refused (its still, reported through `onCeilingRefused`) and Stage 1
///   takes the player of the least recently borrowed holder with no Stage-1 hold, playing or
///   paused; it is told and shows its still, and its playhead is kept so it resumes there when it
///   gets a player again (`takeResumeMs`). With no such holder Stage 1 goes one over the ceiling.
/// - Wait queue (2026-11-12, `testkit/contracts/video-pool.md`). A refused or evicted Stage-2
///   surface `wait`s while it is mounted. Waiters that want to play come before paused ones, first
///   come first served within each group. A freed slot is reserved for the first waiter, whose
///   `onAvailable` runs on the next main-queue turn; a Stage-2 borrow by anyone else counts
///   reserved slots as taken, Stage 1 ignores them (a reservation it overruns lapses). Nobody
///   gives way inside Stage 2: a held video, playing or paused, keeps its player.
/// - An extra given back is parked, not destroyed, so a borrow in the next seconds reuses it;
///   after `parkSeconds` it is destroyed while the pool is over its size. Memory pressure
///   (`onMemoryPressure`) destroys idle players and the story's previous-page hold.
/// - Bookkeeping is bounded by the live players (N8), plus eviction observers, waiters and the
///   playheads of evicted keys while their surface is mounted.
///
/// All calls run on the main thread.
final class VideoPlayerPool: @unchecked Sendable {
    private struct Holder {
        var url: URL
        let player: AVPlayer
        var seq: UInt64
        /// One rank per current hold.
        var holds: [PoolPriority]
        /// Where the player resumes after its idle item was let go, or after Stage 1 took the
        /// key's last player; taken once by `takeResumeMs`.
        var resumeMs: Int64? = nil
        /// The highest rank among the current holds.
        /// No hold: a Stage-2 rank, so it never counts as a story page.
        var priority: PoolPriority { holds.min() ?? .onScreen }
    }

    private struct Waiter {
        let token: UUID
        let key: String
        let url: URL
        /// When it started waiting; `updateWait` keeps it.
        let seq: UInt64
        var wantsPlay: Bool
        let onAvailable: @MainActor () -> Void
    }

    private struct FreePlayer {
        let player: AVPlayer
        let key: String
        let url: URL
        /// It was at its end when given back: a revisit restarts.
        let finished: Bool
        /// When it was given back while the pool was over its size; nil when it is within it.
        var parkedAt: TimeInterval?
        /// When it was given back.
        let freedAt: TimeInterval
        /// Its playhead when its item was let go; nil while it keeps its item.
        var resumeMs: Int64? = nil
    }

    /// A showing this close to its end counts as finished, as on Android.
    static let finishedWithin: TimeInterval = 0.5

    /// How long an extra player given back is kept for reuse before it is destroyed (OD-24), and
    /// how long any player given back keeps its item before letting it go.
    static let parkSeconds: TimeInterval = 8

    let maxPlayers: Int
    /// The live-player ceiling in force: holders alive at once, pooled and extra (OD-24).
    private(set) var ceiling: Int
    /// Called when a Stage-2 borrow is refused at the ceiling; the SDK reports it as health.
    var onCeilingRefused: (@MainActor () -> Void)?
    private let clock: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    /// Runs a task on the next main-queue turn: a waiter's `onAvailable`, never inside the call
    /// that freed its slot.
    private let post: (@escaping @MainActor () -> Void) -> Void
    private var trimScheduled = false
    private let makeItem: @MainActor (URL) -> AVPlayerItem
    private let releaseItem: @MainActor (AVPlayerItem) -> Void
    private let makePlayer: @MainActor (AVPlayerItem) -> AVPlayer
    private var holders: [String: Holder] = [:]
    private var free: [FreePlayer] = []
    private var evictionObservers: [String: [UUID: @MainActor () -> Void]] = [:]
    private var waiters: [Waiter] = []
    /// Keys a freed slot is held for until they borrow, cancel, or Stage 1 takes the slot.
    private var reserved: [String] = []
    /// The playhead of a key whose player the pool took (decision 2a), for that key's next borrow
    /// of the same URL while it waits. Dropped at that key's next borrow or when it stops waiting.
    /// At most `ceiling` entries, the oldest dropped first (N8): a key that never waits keeps its
    /// entry until it borrows again.
    private var evictedResume: [String: (url: URL, ms: Int64, at: UInt64)] = [:]
    private var seq: UInt64 = 0

    init(
        maxPlayers: Int = maxPoolPlayers(deviceClass: deviceClassFor(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)),
        ceiling: Int? = nil,
        onCeilingRefused: (@MainActor () -> Void)? = nil,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, task in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { task() } }
        },
        post: @escaping (@escaping @MainActor () -> Void) -> Void = { task in
            DispatchQueue.main.async { MainActor.assumeIsolated { task() } }
        },
        makeItem: @escaping @MainActor (URL) -> AVPlayerItem,
        releaseItem: @escaping @MainActor (AVPlayerItem) -> Void = { _ in },
        makePlayer: @escaping @MainActor (AVPlayerItem) -> AVPlayer = { AVPlayer(playerItem: $0) }
    ) {
        self.maxPlayers = max(1, maxPlayers)
        self.ceiling = max(self.maxPlayers, ceiling ?? livePlayerCeiling(poolSize: self.maxPlayers))
        self.onCeilingRefused = onCeilingRefused
        self.clock = clock
        self.schedule = schedule
        self.post = post
        self.makeItem = makeItem
        self.releaseItem = releaseItem
        self.makePlayer = makePlayer
    }

    /// One hold on the player for `key`, or nil when refused (Stage 2 at the ceiling, which is
    /// reported through `onCeilingRefused`). The caller shows its still on nil, and `wait`s.
    @MainActor
    func borrow(key: String, url: URL, priority: PoolPriority) -> AVPlayer? {
        seq &+= 1
        if var existing = holders[key] {
            let repointed = existing.url != url
            // A failed item never recovers: a borrow never inherits a failure, it retries.
            if repointed || Self.hasFailed(existing.player) {
                existing.url = url
                existing.resumeMs = nil
                replaceItem(of: existing.player, with: makeItem(url))
            }
            if repointed {
                // The other holders' URL is gone: their holds end and they are told (R2-06c).
                existing.holds = []
            }
            existing.seq = seq
            existing.holds.append(priority)
            holders[key] = existing
            leaveQueue(key)
            if repointed { notifyEvicted(key) }
            return existing.player
        }
        var victim: String?
        if !priority.isStage1, holders.count + reserved.filter({ $0 != key }).count >= ceiling {
            // Stage 2 at the ceiling, counting the slots reserved for waiters: refused.
            onCeilingRefused?()
            return nil
        } else if priority.isStage1, free.isEmpty, holders.count >= ceiling {
            // Stage 1 is never refused (OD-24): it takes the player of the least recently borrowed
            // holder with no Stage-1 hold. With none, it goes one over the ceiling.
            victim = leastRecentStageTwo()
        }
        if let victim, let taken = holders.removeValue(forKey: victim) { take(taken, of: victim) }
        // The victim is told once the borrower holds its slot, so a `wait` it starts sees the
        // pool as it is.
        defer {
            leaveQueue(key)
            if priority.isStage1 { lapseReservations() }
            if let victim { notifyEvicted(victim) }
        }
        // Where the pool left this key's last player, if it took it (decision 2a). Only a showing
        // that waits resumes there; otherwise the surface's own start wins (OD-22) (R3-01).
        let waits = waiters.contains { $0.key == key }
        let evictedMs = evictedResume.removeValue(forKey: key).flatMap { waits && $0.url == url ? $0.ms : nil }
        // Prefer the free player that last played this key and URL, so it resumes.
        let match = free.lastIndex { $0.key == key && $0.url == url } ?? (free.isEmpty ? nil : free.count - 1)
        if let match {
            let reused = free.remove(at: match)
            var resumeMs: Int64?
            if reused.url != url || reused.player.currentItem == nil || Self.hasFailed(reused.player) {
                replaceItem(of: reused.player, with: makeItem(url))
                // Its idle item was let go: the new one resumes where the old one was.
                if reused.url == url, reused.key == key, !reused.finished { resumeMs = reused.resumeMs }
            } else if reused.key != key || reused.finished {
                // Same file under another key (two rail cards), or a finished showing: restart.
                reused.player.seek(to: .zero)
            }
            // Otherwise the same key and URL: it resumes where it was (N2).
            holders[key] = Holder(url: url, player: reused.player, seq: seq, holds: [priority], resumeMs: evictedMs ?? resumeMs)
            return reused.player
        }
        let player = makePlayer(makeItem(url))
        holders[key] = Holder(url: url, player: player, seq: seq, holds: [priority], resumeMs: evictedMs)
        return player
    }

    /// Releases one hold of `priority` on `key` while it is still `player`'s. A stale call
    /// (evicted, re-pointed away, released, re-borrowed by another player) is a no-op. The key's
    /// rank becomes the highest of the holds left. The last hold pauses the player and keeps it,
    /// or destroys it while the pool is over its size.
    @MainActor
    func giveBack(key: String, player: AVPlayer, priority: PoolPriority) {
        guard var holder = holders[key], holder.player === player,
              let index = holder.holds.firstIndex(of: priority) else { return }
        holder.holds.remove(at: index)
        guard holder.holds.isEmpty else {
            holders[key] = holder
            return
        }
        holders[key] = nil
        player.pause()
        let now = clock()
        let parked = holders.count + free.count >= maxPlayers
        free.append(FreePlayer(
            player: player, key: key, url: holder.url, finished: Self.isFinished(player),
            parkedAt: parked ? now : nil, freedAt: now))
        scheduleTrim(after: Self.parkSeconds)
        wakeWaiters()
    }

    /// Where `key`'s player should start because its idle item was let go and a new one made, or
    /// because Stage 1 took the key's last player, in ms; nil otherwise. Taken once: the first surface to open the player resumes it.
    @MainActor
    func takeResumeMs(for key: String, player: AVPlayer) -> Int64? {
        guard var holder = holders[key], holder.player === player, let resumeMs = holder.resumeMs else { return nil }
        holder.resumeMs = nil
        holders[key] = holder
        return resumeMs
    }

    /// Ends the hold of a node whose key nobody else can borrow (OD-15): the player is destroyed,
    /// not kept idle. A stale call (evicted, re-pointed away, re-borrowed by another player) is a
    /// no-op.
    @MainActor
    func discard(key: String, player: AVPlayer) {
        guard let holder = holders[key], holder.player === player else { return }
        holders[key] = nil
        destroy(player)
        wakeWaiters()
    }

    /// Calls `handler` if `key`'s player is evicted while the observer is registered.
    @MainActor
    func observeEviction(of key: String, _ handler: @escaping @MainActor () -> Void) -> UUID {
        let id = UUID()
        evictionObservers[key, default: [:]][id] = handler
        return id
    }

    @MainActor
    func removeEvictionObserver(_ id: UUID, for key: String) {
        evictionObservers[key]?[id] = nil
        if evictionObservers[key]?.isEmpty == true { evictionObservers[key] = nil }
    }

    /// Memory pressure (OD-24): destroys every free and parked player, and takes back the players
    /// held only as the story's previous page (the plan borrows it again when it next plans).
    /// Players anything else holds stay. The SDK calls it on a memory warning and on entering the
    /// background.
    @MainActor
    func onMemoryPressure() {
        let idle = free
        free.removeAll()
        idle.forEach { destroy($0.player) }
        let prevOnly = holders.filter { !$0.value.holds.isEmpty && $0.value.holds.allSatisfy { $0 == .viewerPrev } }
        for key in prevOnly.keys { evict(key: key) }
        wakeWaiters()
    }

    /// Destroys parked players while the pool is over its size, oldest first, once each has been
    /// parked `parkSeconds`. Then every player free for `parkSeconds` lets go of its item, keeping
    /// its playhead: an idle item keeps downloading its file through the range cache, and keeps a
    /// decoder. A younger one schedules the next pass. Never touches held players.
    @MainActor
    func trimParked() {
        trimScheduled = false
        let now = clock()
        var nextIn: TimeInterval?
        while holders.count + free.count > maxPlayers {
            guard let oldest = free.indices.min(by: { (free[$0].parkedAt ?? -.infinity) < (free[$1].parkedAt ?? -.infinity) })
            else { break }
            if let since = free[oldest].parkedAt, now - since < Self.parkSeconds {
                nextIn = Self.parkSeconds - (now - since)
                break
            }
            destroy(free.remove(at: oldest).player)
        }
        for index in free.indices {
            guard let item = free[index].player.currentItem else { continue }
            let idle = now - free[index].freedAt
            guard idle >= Self.parkSeconds else {
                nextIn = min(nextIn ?? .infinity, Self.parkSeconds - idle)
                continue
            }
            let playhead = item.currentTime()
            if playhead.isNumeric, playhead.seconds > 0 {
                free[index].resumeMs = Int64(playhead.seconds * 1_000)
            }
            replaceItem(of: free[index].player, with: nil)
        }
        if let nextIn { scheduleTrim(after: nextIn) }
    }

    /// Destroys every player, held or free. Later give-backs are no-ops.
    @MainActor
    func release() {
        holders.values.forEach { destroy($0.player) }
        free.forEach { destroy($0.player) }
        holders.removeAll()
        free.removeAll()
        waiters.removeAll()
        reserved.removeAll()
        evictedResume.removeAll()
    }

    /// Queues a refused or evicted Stage-2 surface for the next free slot. `onAvailable` runs on a
    /// later main-queue turn when a slot is reserved for it; the surface then borrows again. It
    /// stays queued, with its place, until a borrow of `key` succeeds or it calls `cancelWait`.
    @MainActor
    func wait(
        key: String, url: URL, priority: PoolPriority, wantsPlay: Bool, onAvailable: @escaping @MainActor () -> Void
    ) -> UUID {
        assert(!priority.isStage1, "Stage 1 is never refused, so it never waits")
        seq &+= 1
        let token = UUID()
        waiters.append(Waiter(token: token, key: key, url: url, seq: seq, wantsPlay: wantsPlay, onAvailable: onAvailable))
        wakeWaiters()
        return token
    }

    /// Moves a waiter between the wants-to-play and paused groups; it keeps its wait time.
    @MainActor
    func updateWait(_ token: UUID, wantsPlay: Bool) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        waiters[index].wantsPlay = wantsPlay
    }

    /// Leaves the queue (the surface closed). A slot reserved for it goes to the next waiter.
    @MainActor
    func cancelWait(_ token: UUID) {
        guard let index = waiters.firstIndex(where: { $0.token == token }) else { return }
        let key = waiters.remove(at: index).key
        if !waiters.contains(where: { $0.key == key }) {
            reserved.removeAll { $0 == key }
            evictedResume[key] = nil
        }
        wakeWaiters()
    }

    // MARK: - Test seams

    @MainActor var heldKeys: Set<String> { Set(holders.keys) }
    /// The waiting keys in the order they would be woken.
    @MainActor var queuedKeys: [String] { queue().map(\.key) }
    @MainActor var livePlayerCount: Int { holders.count + free.count }
    @MainActor func heldPlayer(for key: String) -> AVPlayer? { holders[key]?.player }
    @MainActor func priority(of key: String) -> PoolPriority? { holders[key]?.priority }
    /// Every bookkeeping entry; bounded by the live players and the mounted surfaces (N8).
    @MainActor var bookkeepingCount: Int {
        holders.count + free.count + evictionObservers.values.reduce(0) { $0 + $1.count } + waiters.count
            + evictedResume.count
    }

    // MARK: - Private

    @MainActor
    private func scheduleTrim(after delay: TimeInterval) {
        guard !trimScheduled else { return }
        trimScheduled = true
        schedule(delay) { [weak self] in self?.trimParked() }
    }

    /// Waiters in wake order: those that want to play first, then paused ones, each longest
    /// waiting first.
    private func queue() -> [Waiter] {
        waiters.sorted { ($0.wantsPlay ? 0 : 1, $0.seq) < ($1.wantsPlay ? 0 : 1, $1.seq) }
    }

    /// Reserves each free slot for the first waiter not yet served and runs its `onAvailable` on
    /// the next turn: one waiter per slot. A waiter whose key is held (re-pointed away, N5) waits
    /// for that key to be let go, so two URLs never take turns re-pointing it.
    @MainActor
    private func wakeWaiters() {
        for waiter in queue() where holders.count + reserved.count < ceiling {
            guard holders[waiter.key] == nil, !reserved.contains(waiter.key) else { continue }
            reserved.append(waiter.key)
            log.d("Video player handed to a waiting video (key=\(waiter.key), url=\(waiter.url.lastPathComponent))")
            let token = waiter.token
            post { [weak self] in
                // A surface that closed meanwhile has cancelled: nothing runs.
                guard let self, let waiter = self.waiters.first(where: { $0.token == token }) else { return }
                waiter.onAvailable()
            }
        }
    }

    /// A borrow of `key` succeeded: its waiters and its reservation are done.
    @MainActor
    private func leaveQueue(_ key: String) {
        waiters.removeAll { $0.key == key }
        reserved.removeAll { $0 == key }
    }

    /// Stage 1 ignores reservations: those it overran lapse, the reserved waiter last in queue
    /// order first (the same rule on every core). The woken waiter's borrow is then refused and it
    /// keeps its place.
    @MainActor
    private func lapseReservations() {
        while !reserved.isEmpty, holders.count + reserved.count > ceiling {
            let order = queue().map(\.key)
            let last = reserved.max { (order.firstIndex(of: $0) ?? .max) < (order.firstIndex(of: $1) ?? .max) }
            reserved.removeAll { $0 == last }
        }
    }

    /// The least recently borrowed holder with no Stage-1 hold, playing or paused.
    private func leastRecentStageTwo() -> String? {
        holders.filter { $0.value.holds.allSatisfy { !$0.isStage1 } }
            .min(by: { $0.value.seq < $1.value.seq })?.key
    }

    @MainActor
    private func evict(key: String) {
        guard let holder = holders.removeValue(forKey: key) else { return }
        take(holder, of: key)
        notifyEvicted(key)
    }

    /// Destroys a holder's player the pool takes back, keeping its playhead for the key's next
    /// borrow of the same URL (decision 2a). A finished showing keeps nothing: it restarts.
    @MainActor
    private func take(_ holder: Holder, of key: String) {
        let playhead = holder.player.currentTime()
        if !Self.isFinished(holder.player), playhead.isNumeric, playhead.seconds > 0 {
            seq &+= 1
            evictedResume[key] = (holder.url, Int64(playhead.seconds * 1_000), seq)
            if evictedResume.count > ceiling, let oldest = evictedResume.min(by: { $0.value.at < $1.value.at })?.key {
                evictedResume[oldest] = nil
            }
        } else {
            evictedResume[key] = nil
        }
        destroy(holder.player)
    }

    @MainActor
    private func notifyEvicted(_ key: String) {
        evictionObservers[key]?.values.forEach { $0() }
    }

    @MainActor
    private func destroy(_ player: AVPlayer) {
        player.pause()
        replaceItem(of: player, with: nil)
    }

    /// Every item the pool drops or replaces is handed to `releaseItem` first: AVFoundation never
    /// cancels the requests of an item it lets go, so the range cache would keep downloading it.
    @MainActor
    private func replaceItem(of player: AVPlayer, with item: AVPlayerItem?) {
        if let old = player.currentItem { releaseItem(old) }
        player.replaceCurrentItem(with: item)
    }

    private static func hasFailed(_ player: AVPlayer) -> Bool {
        player.currentItem?.status == .failed
    }

    /// Whether the player is at the end of its item (within `finishedWithin`).
    static func isFinished(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem, item.duration.isNumeric else { return false }
        return item.currentTime().seconds >= item.duration.seconds - finishedWithin
    }
}
