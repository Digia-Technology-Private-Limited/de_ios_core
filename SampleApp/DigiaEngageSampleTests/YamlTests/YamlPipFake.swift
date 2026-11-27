import AVFoundation
import UIKit
@testable import DigiaEngage

/// The PiP parity fake: a black 12 s video frozen 4 s in, playing. Mirrors
/// the Flutter `_YamlFakeVideo` (black surface, 12 s, position 4 s, isPlaying)
/// and the Android pinned fake, so the PiP chrome progress matches every
/// stack. Test-only: no `Sources/` change.
final class YamlFakePipPlayer: AVPlayer {
    private let stubItem: YamlFakePipItem

    /// `url` decides whether the clip can load at all, the way the real
    /// player answers a missing file with a failure: a `does-not-exist` URL
    /// or a `file://` URL with nothing behind it reports `.failed` so the
    /// orchestrator drops the campaign before display (f38), exactly as the
    /// Flutter fake throwing on such URLs does. Anything else is the usual
    /// frozen clip below.
    init(url: String) {
        let playable: Bool
        if url.contains("does-not-exist") {
            playable = false
        } else if let fileURL = URL(string: url), fileURL.isFileURL {
            playable = FileManager.default.fileExists(atPath: fileURL.path)
        } else {
            playable = true
        }
        self.stubItem = YamlFakePipItem(playable: playable)
        super.init()
    }

    /// Whether the fake is "playing". Starts true (autoplay); `play()` and
    /// `pause()` flip it so the chrome's play/pause glyph and the
    /// pause/play Clicked reports toggle exactly like a real player, while
    /// the frame itself never moves (see `currentTime`).
    private var playing = true

    override var currentItem: AVPlayerItem? { stubItem }

    /// Frozen except for the play/pause flag above: the chrome shows the
    /// pause glyph and the progress stays at 4/12 s, so goldens never
    /// capture a moving frame.
    override var rate: Float {
        get { playing ? 1 : 0 }
        set { /* rate is derived from play()/pause() below */ }
    }

    override func currentTime() -> CMTime { CMTime(seconds: 4, preferredTimescale: 600) }

    /// Autoplay, mute-toggle pause and backgrounding all route through these.
    /// They flip the playing flag (with manual KVO, so the orchestrator's
    /// `rate` publisher sees it exactly as a real rate change) but never
    /// move the frame.
    override func play() {
        willChangeValue(for: \.rate)
        playing = true
        didChangeValue(for: \.rate)
    }

    override func pause() {
        willChangeValue(for: \.rate)
        playing = false
        didChangeValue(for: \.rate)
    }

    /// `endVideo` runs the clip out by seeking near its end, the way the
    /// hand-written tests do (see `inlineRunOut`): a seek into the last half
    /// second posts the end-of-item notification, so the orchestrator honors
    /// `onMediaEnd` (f32) exactly as playback reaching the end does.
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) async -> Bool {
        if time.seconds >= 11.5 {
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: stubItem)
        }
        return true
    }
}

/// A stub item reporting a 12 s ready video. The asset behind it never loads
/// (its status is pinned below), so only the duration here is ever read.
final class YamlFakePipItem: AVPlayerItem {
    private let playable: Bool

    init(playable: Bool = true) {
        self.playable = playable
        super.init(asset: AVMutableComposition(), automaticallyLoadedAssetKeys: nil)
    }

    override var duration: CMTime { CMTime(seconds: 12, preferredTimescale: 600) }

    /// Ready from the first observation, so the orchestrator reveals the
    /// window instead of abandoning the load — or failed, so it drops the
    /// campaign before display exactly as an unloadable file does.
    override var status: Status { playable ? .readyToPlay : .failed }
}

/// The fake renders no frames, so its layer stays transparent (showing the
/// window's navy backdrop) until forced: paint it opaque black, the colour
/// the Flutter/Android fakes draw, so the golden matches every stack. Only
/// the floater's own layer is touched — story inline players keep their real
/// frames — identified through the layer's player.
@MainActor
func blackenYamlPipSurface(in window: UIWindow, player: AVPlayer) {
    func walk(_ view: UIView) {
        if let container = view as? InlineStoryPlayerContainer,
           container.playerLayer.player === player
        {
            container.playerLayer.backgroundColor = UIColor.black.cgColor
            container.playerLayer.opacity = 1
        }
        for subview in view.subviews { walk(subview) }
    }
    walk(window)
}
