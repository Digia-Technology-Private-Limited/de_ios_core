import AVFoundation
import Foundation

// Ranking below mirrors Android's VideoPlayerPool (itself adapted from
// Media3 1.9.0 `DefaultPreloadManager`, Apache-2.0, notice kept on Android):
// the same four ranks in the same order. iOS case names follow Swift
// lowerCamelCase instead of Android's UPPER_SNAKE_CASE (intended difference).

/// Who a pooled player is held for, highest first. The rank travels with the
/// holder and gates eviction: a full pool releases only a holder ranked
/// strictly below the newcomer; a newcomer that outranks nothing gets no
/// pooled player and renders its still instead (D3).
internal enum PoolPriority: Int, Sendable, Equatable, Comparable {
    case onScreen = 0
    case viewerNext = 1
    case viewerPrev = 2
    case railThumb = 3

    static func < (lhs: PoolPriority, rhs: PoolPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Coarse device bucket; only the pool size reads it today.
internal enum DeviceClass: Sendable, Equatable {
    case low
    case mid
    case high
}

/// Placeholder pool sizes per `DeviceClass`. TODO(measure #157): replace with
/// measured values once story playback is profiled on low/mid/high devices.
/// Do NOT write a test locking in these numbers; test `deviceClassFor`
/// boundaries instead.
internal func maxPoolPlayers(deviceClass: DeviceClass) -> Int {
    switch deviceClass {
    case .low: 2
    case .mid: 3
    case .high: 4
    }
}

/// Classifies `physicalMemoryBytes` (`ProcessInfo.processInfo.physicalMemory`);
/// thresholds are heuristics. Unknown (0) degrades to the middle, never throws.
internal func deviceClassFor(physicalMemoryBytes: UInt64) -> DeviceClass {
    switch physicalMemoryBytes {
    case 0:
        .mid
    case ..<(4 * 1_024 * 1_024 * 1_024):
        .low
    case ..<(7 * 1_024 * 1_024 * 1_024):
        .mid
    default:
        .high
    }
}

/// Reads the device bucket; an unknown memory size degrades to `DeviceClass.mid`.
internal func deviceClassOf(processInfo: ProcessInfo = .processInfo) -> DeviceClass {
    deviceClassFor(physicalMemoryBytes: processInfo.physicalMemory)
}

/// The one player pool per SDK initialization (D3): constructor-injected (`factory`,
/// `maxPlayers`, `onEvict`), never global. Lazy: no player exists until the
/// first `obtain`.
///
/// Eviction is gated (Android R-P2-01): a full pool releases the tail holder
/// only when it ranks strictly below the newcomer. A newcomer that outranks
/// nothing gets nil (no pooled player) instead of killing a higher-ranked
/// holder — a railThumb obtain can never evict an onScreen player. The victim
/// is reported to `onEvict` so its surface can degrade to its still explicitly.
///
/// Consequence on low (2 slots): the plan's middle case demands 3 players
/// (current, next, previous); the VIEWER_PREV demand arrives last and outranks
/// nothing, so its obtain returns nil and the viewer renders the still (D3
/// degrade rule). Sizes stay placeholders TODO(measure #157).
///
/// Same key + same URL hands over the same object WITHOUT re-pointing the item
/// (Android R-P3-01): the borrowed frame survives, no re-buffer, no gap. A new
/// URL on a held key re-points in place — never a second player for one key.
///
/// Stale handovers drop the same way upstream drops stale preload completions:
/// the pool only ever acts on keys it still holds, so a `giveBack` that
/// arrives after its holder was evicted, or after `release`, finds no key and
/// is a silent no-op — never a throw.
///
/// Looping lives inside the pool entry (D3): each holder keeps an optional
/// `AVPlayerLooper` rebuilt on every re-point while `looping` is set, torn
/// down on `giveBack`/`release`/evict. Intended difference from Android, where
/// `takeOver` sets ExoPlayer's built-in `repeatMode`: `AVPlayer` has no repeat
/// mode, so the entry owns the looper object instead. The loop flag itself is
/// a per-borrow property; the borrower (lane E `MediaVideo`) sets it through
/// `setLooping(_:forKey:)` at take-over time.
///
/// Decoder exhaustion (AVFoundation -11839 / item `.failed`) is NOT observed
/// here: item-status observation and the health event land with lane C's health
/// hook (T6) and lane E's `MediaVideo` (T9), the only layers that see item
/// status. This pool's contribution to that rule is the degrade half — nil or
/// eviction means "render the still" — already covered below. (Recorded
/// deferral; the health half is not silently dropped, it has an owner.)
///
/// Callers: every non-nil `obtain` has a `giveBack` on disappear; `SDKServices`
/// calls `release` on teardown (which also covers SDK re-init: `initialize()`
/// never replaces a live `SDKServices`, it early-returns when one exists, so
/// there is no reassign-without-release path — Android R-P2-02 has no iOS
/// counterpart). A nil obtain means "demand exceeds supply" — render the still,
/// never build around the pool.
///
/// Threading: `NSLock`-guarded like `PathNetworkMonitor`; `AVPlayer` calls made
/// under the lock are the synchronous setters only (no waiting, no I/O).
internal final class VideoPlayerPool: @unchecked Sendable {
    private struct Holder {
        let key: String
        var url: URL
        var priority: PoolPriority
        let player: AVQueuePlayer
        var looper: AVPlayerLooper?
        var looping: Bool
        var seq: UInt64
    }

    private let factory: any PlayerFactory
    private let maxPlayers: Int
    private let onEvict: ((String) -> Void)?
    private let lock = NSLock()
    private var holders: [String: Holder] = [:]
    private var free: [AVQueuePlayer] = []
    private var seq: UInt64 = 0

    init(factory: any PlayerFactory, maxPlayers: Int, onEvict: ((String) -> Void)? = nil) {
        self.factory = factory
        self.maxPlayers = maxPlayers
        self.onEvict = onEvict
    }

    /// Serves the player for `key`, or nil when the pool cannot serve it: the
    /// same instance when the key is already held (re-pointed with `url` when
    /// it changed — a handover, never a new player; untouched when the URL is
    /// the same, so the current frame survives); a freed player re-pointed with
    /// `url` when one is free; a fresh `factory` player when the pool has room;
    /// when full, only by releasing a holder ranked strictly below `priority`
    /// (reported to `onEvict`). A newcomer that outranks nothing gets nil.
    func obtain(key: String, url: URL, priority: PoolPriority) -> AVPlayer? {
        var evictedKey: String?
        let player: AVPlayer? = lock.withLock {
            if var existing = holders[key] {
                if existing.url != url {
                    existing.url = url
                    repointLocked(entry: &existing, url: url)
                }
                existing.priority = priority
                seq &+= 1
                existing.seq = seq
                holders[key] = existing
                return existing.player
            }
            if let reused = free.popLast() {
                // A freed player always returns with looping cleared
                // (`giveBack` resets it), so no looper is rebuilt here; the
                // next borrower sets it via `setLooping(_:forKey:)`.
                let item = AVPlayerItem(url: url)
                reused.replaceCurrentItem(with: item)
                seq &+= 1
                holders[key] = Holder(
                    key: key, url: url, priority: priority,
                    player: reused, looper: nil, looping: false, seq: seq
                )
                return reused
            }
            if holders.count >= max(1, maxPlayers) {
                guard let tail = evictableTailLocked(), tail.priority > priority else {
                    // Nothing ranked below the newcomer: it goes unfilled
                    // (still), never served by killing a holder ranked
                    // at-or-above it.
                    return nil
                }
                holders.removeValue(forKey: tail.key)
                detachLocked(entry: tail)
                evictedKey = tail.key
            }
            let created = factory.makePlayer()
            let item = AVPlayerItem(url: url)
            created.replaceCurrentItem(with: item)
            seq &+= 1
            holders[key] = Holder(
                key: key, url: url, priority: priority,
                player: created, looper: nil, looping: false, seq: seq
            )
            return created
        }
        if let evictedKey {
            onEvict?(evictedKey)
        }
        return player
    }

    /// Frees `key`'s player for reuse: stops any looping, pauses, keeps the
    /// item (a same-key re-borrow resumes from its frame). A missing key
    /// (never held, evicted, released) is a silent no-op.
    func giveBack(key: String) {
        lock.withLock {
            guard var holder = holders.removeValue(forKey: key) else { return }
            holder.looper = nil
            holder.looping = false
            holder.player.pause()
            free.append(holder.player)
        }
    }

    /// Sets the loop flag for a held key, rebuilding the entry's looper
    /// against the current item. A missing key is a silent no-op. Called by the
    /// borrower at take-over time; cleared by `giveBack`.
    func setLooping(_ looping: Bool, forKey key: String) {
        lock.withLock {
            guard var holder = holders[key] else { return }
            holder.looping = looping
            holder.looper = nil
            if looping, let item = holder.player.currentItem {
                holder.looper = AVPlayerLooper(player: holder.player, templateItem: item)
            }
            holders[key] = holder
        }
    }

    /// Keys currently holding players. Tests assert giveBack pairing through
    /// this (handover keeps the key, a move-past frees it) instead of
    /// reflecting on `holders` (Android R-P3-05 nit, applied here first).
    func heldKeys() -> Set<String> {
        lock.withLock { Set(holders.keys) }
    }

    /// Whether `key` currently loops. Test seam for the entry-owned looper
    /// lifecycle (same precedent as `heldKeys`).
    func isLooping(key: String) -> Bool {
        lock.withLock { holders[key]?.looping ?? false }
    }

    /// Releases every player, held or free: looping torn down, paused,
    /// detached (current item cleared). Later `giveBack`s are silent no-ops;
    /// later `obtain`s create fresh players.
    func release() {
        lock.withLock {
            for entry in holders.values {
                detachLocked(entry: entry)
            }
            holders.removeAll()
            for player in free {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
            free.removeAll()
        }
    }

    /// The eviction candidate: the lowest-ranked holder, ties to the
    /// least-recently-obtained (Android R-P2-03: least-recent, not most).
    private func evictableTailLocked() -> Holder? {
        holders.values.min { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            return a.seq < b.seq
        }
    }

    /// Re-points an entry at a new URL, rebuilding its looper when looping.
    /// Same-URL handovers never reach here (no re-prepare, no gap).
    private func repointLocked(entry: inout Holder, url: URL) {
        entry.looper = nil
        let item = AVPlayerItem(url: url)
        entry.player.replaceCurrentItem(with: item)
        if entry.looping {
            entry.looper = AVPlayerLooper(player: entry.player, templateItem: item)
        }
    }

    /// Detaches a player leaving the pool (evict/release): no looping, no
    /// playback, no item.
    private func detachLocked(entry: Holder) {
        var entry = entry
        entry.looper = nil
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
    }
}
