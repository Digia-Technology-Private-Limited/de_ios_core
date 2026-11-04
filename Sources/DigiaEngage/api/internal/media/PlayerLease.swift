import AVFoundation
import Foundation

/// A borrowed pool player with its lifecycle (D12): the share rule travels
/// with it — a second obtain of an already-held key shares the committed
/// holder's instance, and releasing a share never frees it. Only the committed
/// holder's release returns the player to the pool.
///
/// Never traps: `release()` is idempotent, a no-op when eviction or teardown
/// already dropped the key, and a stale release after a later re-borrow is
/// dropped by the pool's identity check. Safe to call from `deinit` (all
/// mutable state is lock-guarded; the pool frees under its own lock).
final class PlayerLease: @unchecked Sendable {
    private let pool: VideoPlayerPool
    let key: String
    let player: AVPlayer
    /// True when the key was already held by this obtain: a handover share,
    /// never freed here. Only the committed holder's release frees.
    let shared: Bool

    private let lock = NSLock()
    private var released = false

    init(pool: VideoPlayerPool, key: String, player: AVPlayer, shared: Bool) {
        self.pool = pool
        self.key = key
        self.player = player
        self.shared = shared
    }

    /// Idempotent: the committed holder's release frees through the pool — a
    /// no-op when eviction or teardown already dropped the key, and a stale
    /// release after a later re-borrow is dropped by the pool's identity
    /// check. A share's release never frees.
    func release() {
        let shouldFree: Bool = lock.withLock {
            guard !released else { return false }
            released = true
            return !shared
        }
        if shouldFree {
            pool.giveBackIfHeldBy(key: key, player: player)
        }
    }
}

/// The pool for the no-SDK host case (D12): a keyed showing with no SDK
/// services (tests, or a host that never initialized) still borrows through
/// the same lease path instead of owning a player outright. Single slot —
/// demand beyond it degrades to the still through the usual refused-borrow
/// path. An evicted holder's item is detached by the pool, which the showing
/// already observes as a degrade-to-still (the same signal a refused borrow
/// ends on).
enum NoSdkVideoPool {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pool: VideoPlayerPool?

    /// The process-wide single-slot fallback pool. Tests inject a fake factory
    /// and reset between cases through `resetForTesting`.
    static func shared(factory: (any PlayerFactory)? = nil) -> VideoPlayerPool {
        lock.withLock {
            if let pool { return pool }
            let created = VideoPlayerPool(
                factory: factory ?? DefaultPlayerFactory(), maxPlayers: 1)
            pool = created
            return created
        }
    }

    static func resetForTesting() {
        lock.withLock { pool = nil }
    }
}
