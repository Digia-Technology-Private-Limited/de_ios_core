import AVFoundation

/// The video boundary: a player that serves the Test Kit's `movie.mp4` from disk and never plays.
///
/// `AVPlayer` reads its URL through the system's media stack, not `URLSession`, so the stub backend cannot serve
/// it. This one reaches `readyToPlay` from the local file, which is what reveals a PiP window, and stays at the
/// first frame, so a golden never depends on how far a clip has run.
final class PausedPlayer: AVPlayer, @unchecked Sendable {
    convenience init(forRemote _: String) {
        self.init(url: WorkspaceFixtures.testkitAssets.appendingPathComponent("movie.mp4"))
        actionAtItemEnd = .pause
    }

    override func play() {}
}
