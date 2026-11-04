import AVFoundation
import Foundation

// Ranking and sizes mirror Android's VideoPlayerPool (adapted there from Media3 1.9.0
// `DefaultPreloadManager`, Apache-2.0, notice kept on Android): the same four ranks in the same
// order. Case names follow Swift lowerCamelCase (intended difference).

/// Who a pooled player is held for, highest first. The rank gates eviction: a full pool takes
/// back only a player ranked strictly below the newcomer.
enum PoolPriority: Int, Sendable, Comparable {
    /// On screen and wants to play now (a floater, PIP, a story page, a canvas or nudge video).
    case onScreen = 0
    case viewerNext = 1
    case viewerPrev = 2
    case railThumb = 3

    static func < (lhs: PoolPriority, rhs: PoolPriority) -> Bool { lhs.rawValue < rhs.rawValue }
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
///   another key, restarts at 0.
/// - A URL change under a held key re-points the same player (N5: the surface gives back the old
///   URL first, so nothing stays held for it).
/// - When the pool is full, a newcomer takes back the lowest-ranked, least recently borrowed
///   player only if that one ranks strictly below it; the evicted holder is told and shows its
///   still. Otherwise an on-screen borrow gets an extra player, destroyed when it is given back
///   while the pool is over its size (OD-1, N7); any other borrow is refused and reports nothing.
/// - Bookkeeping is bounded by the live players (N8), plus eviction observers while their
///   surface is mounted.
///
/// All calls run on the main thread.
final class VideoPlayerPool: @unchecked Sendable {
    private struct Holder {
        var url: URL
        var priority: PoolPriority
        let player: AVPlayer
        var seq: UInt64
        var holds: Int
    }

    private struct FreePlayer {
        let player: AVPlayer
        let key: String
        let url: URL
        /// It was at its end when given back: a revisit restarts.
        let finished: Bool
    }

    /// A showing this close to its end counts as finished, as on Android.
    static let finishedWithin: TimeInterval = 0.5

    let maxPlayers: Int
    private let makeItem: @MainActor (URL) -> AVPlayerItem
    private var holders: [String: Holder] = [:]
    private var free: [FreePlayer] = []
    private var evictionObservers: [String: [UUID: @MainActor () -> Void]] = [:]
    private var seq: UInt64 = 0

    init(
        maxPlayers: Int = maxPoolPlayers(deviceClass: deviceClassFor(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)),
        makeItem: @escaping @MainActor (URL) -> AVPlayerItem
    ) {
        self.maxPlayers = max(1, maxPlayers)
        self.makeItem = makeItem
    }

    /// One hold on the player for `key`, or nil when refused (pool full, nothing ranked below,
    /// and not on screen). The caller shows its still and reports nothing on nil.
    @MainActor
    func borrow(key: String, url: URL, priority: PoolPriority) -> AVPlayer? {
        seq &+= 1
        if var existing = holders[key] {
            if existing.url != url {
                existing.url = url
                existing.player.replaceCurrentItem(with: makeItem(url))
            }
            // A lower-ranked co-holder never lowers an on-screen player's rank.
            existing.priority = min(existing.priority, priority)
            existing.seq = seq
            existing.holds += 1
            holders[key] = existing
            return existing.player
        }
        // Prefer the free player that last played this key and URL, so it resumes.
        let match = free.lastIndex { $0.key == key && $0.url == url } ?? (free.isEmpty ? nil : free.count - 1)
        if let match {
            let reused = free.remove(at: match)
            if reused.url != url || reused.player.currentItem == nil {
                reused.player.replaceCurrentItem(with: makeItem(url))
            } else if reused.key != key || reused.finished {
                // Same file under another key (two rail cards), or a finished showing: restart.
                reused.player.seek(to: .zero)
            }
            // Otherwise the same key and URL: it resumes where it was (N2).
            holders[key] = Holder(url: url, priority: priority, player: reused.player, seq: seq, holds: 1)
            return reused.player
        }
        if holders.count >= maxPlayers {
            if let tail = evictableTail(), tail.value.priority > priority {
                evict(key: tail.key)
            } else if priority != .onScreen {
                return nil
            }
            // On screen with nothing to take back: an extra player beyond the size (OD-1).
        }
        let player = AVPlayer(playerItem: makeItem(url))
        holders[key] = Holder(url: url, priority: priority, player: player, seq: seq, holds: 1)
        return player
    }

    /// Releases one hold on `key` while it is still `player`'s. A stale call (evicted, released,
    /// re-borrowed by another player) is a no-op. The last hold pauses the player and keeps it,
    /// or destroys it while the pool is over its size.
    @MainActor
    func giveBack(key: String, player: AVPlayer) {
        guard var holder = holders[key], holder.player === player else { return }
        holder.holds -= 1
        guard holder.holds <= 0 else {
            holders[key] = holder
            return
        }
        holders[key] = nil
        player.pause()
        if holders.count + free.count >= maxPlayers {
            destroy(player)
            return
        }
        free.append(FreePlayer(player: player, key: key, url: holder.url, finished: Self.isFinished(player)))
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

    /// Destroys every player, held or free. Later give-backs are no-ops.
    @MainActor
    func release() {
        holders.values.forEach { destroy($0.player) }
        free.forEach { destroy($0.player) }
        holders.removeAll()
        free.removeAll()
    }

    // MARK: - Test seams

    @MainActor var heldKeys: Set<String> { Set(holders.keys) }
    @MainActor var livePlayerCount: Int { holders.count + free.count }
    @MainActor func heldPlayer(for key: String) -> AVPlayer? { holders[key]?.player }
    /// Every bookkeeping entry; bounded by the live players and the mounted surfaces (N8).
    @MainActor var bookkeepingCount: Int {
        holders.count + free.count + evictionObservers.values.reduce(0) { $0 + $1.count }
    }

    // MARK: - Private

    private func evictableTail() -> (key: String, value: Holder)? {
        holders.min { a, b in
            a.value.priority != b.value.priority ? a.value.priority > b.value.priority : a.value.seq < b.value.seq
        }.map { ($0.key, $0.value) }
    }

    @MainActor
    private func evict(key: String) {
        guard let holder = holders.removeValue(forKey: key) else { return }
        destroy(holder.player)
        evictionObservers[key]?.values.forEach { $0() }
    }

    private func destroy(_ player: AVPlayer) {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private static func isFinished(_ player: AVPlayer) -> Bool {
        guard let item = player.currentItem, item.duration.isNumeric else { return false }
        return item.currentTime().seconds >= item.duration.seconds - finishedWithin
    }
}
