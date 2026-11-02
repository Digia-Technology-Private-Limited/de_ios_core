import AVFoundation
import Foundation

/// Builds the bare pooled player. The pool (and later `MediaVideo`'s owned
/// fallback) re-points it; tests inject a fake through `VideoPlayerPool`'s
/// initializer.
///
/// Intended difference from Android's `PlayerFactory` fun interface: iOS vends
/// `AVQueuePlayer` (an `AVPlayer` subclass) so a borrower can attach an
/// `AVPlayerLooper` for looping — `AVPlayer` has no built-in repeat mode the
/// way ExoPlayer's `repeatMode` does. `obtain` still returns `AVPlayer?`.
internal protocol PlayerFactory {
    func makePlayer() -> AVQueuePlayer
}

/// The default factory: a bare `AVQueuePlayer` with no item. Creating it does
/// no I/O and starts no loading; the pool sets the item on `obtain`.
internal struct DefaultPlayerFactory: PlayerFactory {
    func makePlayer() -> AVQueuePlayer { AVQueuePlayer() }
}
