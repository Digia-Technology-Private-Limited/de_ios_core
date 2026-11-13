import AVFoundation
import AVKit
import SwiftUI
import UIKit

internal import DigiaMediaCache
internal import DigiaVideoEngine

extension MediaFit {
    /// The `AVPlayerLayer` gravity for the fit: cover crops, contain letterboxes, fill stretches.
    /// The layer fits the frame relative to its own bounds, so there is no fit maths here (N1).
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .cover: .resizeAspectFill
        case .contain: .resizeAspect
        case .fill: .resize
        }
    }
}

/// What a video shows until its first frame (Q1): the authored thumbnail, else the BlurHash,
/// else the dark backdrop. No frame is cut from the video. A non-blank thumbnail always goes to
/// `MediaImage`, which reports an unusable one as `invalid_url` and draws the BlurHash in its
/// place (R1-17, the same rule on every stack).
enum MediaVideoStill: Equatable {
    case thumbnail(String)
    case blurHash(String)
    case backdrop

    init(thumbnailUrl: String?, blurHash: String?) {
        if let thumbnailUrl, !thumbnailUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .thumbnail(thumbnailUrl)
        } else if let blurHash, !blurHash.isEmpty {
            self = .blurHash(blurHash)
        } else {
            self = .backdrop
        }
    }

    /// Whether something can actually show before the first frame: a usable thumbnail URL or a
    /// BlurHash. Only when nothing can does the spinner appear.
    static func canShow(thumbnailUrl: String?, blurHash: String?) -> Bool {
        if let thumbnailUrl, mediaUsableURL(thumbnailUrl) != nil { return true }
        return !(blurHash ?? "").isEmpty
    }
}

/// The dark ground under a video's still, the same #1A1A1A as Android and Flutter.
let mediaVideoBackdrop = Color(red: 0x1A / 255, green: 0x1A / 255, blue: 0x1A / 255)

/// The one video wrapper every surface renders through. Flat parameters, like `MediaImage`.
///
/// Until the first frame it shows the still (`MediaVideoStill`) on the dark backdrop. A spinner
/// appears only when no still can show, after `spinnerDelay` (~400 ms) with no first frame. When
/// the video can't load (or the URL is unusable) it shows the "Video failed" box, the same box
/// `main`'s nudge video showed, and reports health once: `invalid_url`, `http_4xx` or `decode`.
/// A network failure, a timeout or a 5xx reports nothing. Never throws from the render path.
///
/// The player always comes from the pool (`MediaServices.videoPool`, OD-15), at `poolPriority`.
/// With a `playerKey`, a remount under the same key and URL resumes where it was. Without one the
/// node borrows under a key of its own, stable while it is mounted, and its player is destroyed
/// when it leaves: nothing is left idle for a dead node. An eviction shows the still again, and a
/// refused borrow shows the still and reports nothing. Remote items read through the range
/// cache; `file://` plays directly.
///
/// `showControls` draws `main`'s native playback controls (`AVPlayerViewController`), as canvas
/// and nudge video did on `main`; every other surface leaves it off. The controls appear with
/// the first frame; until then the still shows (OD-7).
///
/// `groundAfterFirstFrame` is what a letterbox shows once the first frame is drawn: black by
/// default (OD-16); a surface passes the colour its `main` drew around the video (OD-18: the
/// inline story's video page passes #1A1A1A). The #1A1A1A backdrop is only the loading ground
/// before the first frame.
///
/// `bare` draws no ground of its own (no backdrop, no ground after the first frame) and no
/// spinner: the caller owns what shows around and behind the video, as on Android. The PIP window
/// and a rail tile pass it, so the window's own background or the tile's still shows through
/// (OD-20, OD-18). A thumbnail or BlurHash given to the video still draws until the first frame.
///
/// `pausesInBackground` pauses the player when the app resigns active and, on becoming active,
/// plays it again only if it was playing (a user's pause or an authored `autoplay: false` stays),
/// the same notifications the story rail and viewer pause on. Canvas and nudge video pass it; the
/// PIP, story and rail surfaces have their own rule.
///
/// Callbacks (the same set on every stack): `onFirstFrame` once per opened URL (again after a
/// handover to a new holder), `onEnded` when playback reaches the end and isn't looping,
/// `onFailure` after health is reported.
///
/// Story surfaces (T8) also use: `startMs`, where an opened player is put (nil keeps the pool's
/// playhead, so a remount resumes); `onReady`, the player at its first frame (the story reads
/// its playhead); `onLost`, kept for the story surfaces, which the engine no longer calls (a
/// taken video shows its still until shown again or tapped).
///
/// `replaceOnDecoderBusy` (default true): on a decoder-busy failure the video takes another
/// video's player; false shows its still instead.
struct MediaVideo: View {
    let url: String
    var fit: MediaFit = .cover
    var thumbnailUrl: String? = nil
    var blurHash: String? = nil
    var loop: Bool = false
    var muted: Bool = true
    /// The level when not muted, 0...1 (the PIP's authored volume). Independent of `muted`.
    var volume: Float = 1
    var autoplay: Bool = true
    var showControls: Bool = false
    var pausesInBackground: Bool = false
    var groundAfterFirstFrame: Color = .black
    var bare: Bool = false
    var playerKey: String? = nil
    var poolPriority: PoolPriority = .onScreen
    var startMs: Int64? = nil
    var onFirstFrame: (() -> Void)? = nil
    var onReady: ((DigiaVideoPlayer) -> Void)? = nil
    var onLost: (() -> Void)? = nil
    var replaceOnDecoderBusy: Bool = true
    var onEnded: (() -> Void)? = nil
    var onFailure: (() -> Void)? = nil
    /// How long a bare backdrop waits for the first frame before showing a spinner. Tests
    /// lengthen it to capture the backdrop alone.
    var spinnerDelay: TimeInterval = MediaVideo.defaultSpinnerDelay

    static let defaultSpinnerDelay: TimeInterval = 0.4

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @StateObject private var box = MediaVideoShowingBox()

    var body: some View {
        let showing = box.showing(pool: services.videoPool, spinnerDelay: spinnerDelay)
        MediaVideoContent(video: self, showing: showing, report: { [services, campaignKey] cause in
            services.reportHealth(campaignKey, .video, cause)
        })
    }

    /// What the engine's `VideoShowing` is given on every update.
    func spec(url: String, key: String?) -> VideoShowingSpec {
        VideoShowingSpec(
            url: url, key: key, priority: poolPriority, loop: loop, muted: muted, volume: volume,
            autoplay: autoplay, replaceOnDecoderBusy: replaceOnDecoderBusy, startMs: startMs,
            hasStill: bare || MediaVideoStill.canShow(thumbnailUrl: thumbnailUrl, blurHash: blurHash))
    }

    @ViewBuilder
    func stillView(_ still: MediaVideoStill) -> some View {
        switch still {
        case let .thumbnail(thumbnail):
            MediaImage(
                url: thumbnail, fit: fit, blurHash: blurHash,
                errorContent: AnyView(MediaStill(fit: fit, blurHash: blurHash)))
        case let .blurHash(hash):
            if let image = BlurHashCache.image(for: hash, size: BlurHashPlaceholderView.decodeSize) {
                if let mode = fit.contentMode {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: mode)
                } else {
                    Image(uiImage: image).resizable()
                }
            }
        case .backdrop:
            EmptyView()
        }
    }
}

/// The failure look of every video: `main`'s nudge "Video failed" box.
struct MediaVideoFailedBox: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
            Text("Video failed")
                .font(Font(SDKInstance.shared.font.resolve(size: 13, weight: 400, italic: false)))
        }
        .foregroundStyle(.white)
    }
}

/// Keeps one engine `VideoShowing` for a `MediaVideo` node, made on first use from the
/// environment's pool. All the decisions live in the showing; the view only draws.
@MainActor
final class MediaVideoShowingBox: ObservableObject {
    private var current: (pool: VideoPlayerPool, showing: VideoShowing)?

    func showing(pool: VideoPlayerPool, spinnerDelay: TimeInterval) -> VideoShowing {
        if let current, current.pool === pool { return current.showing }
        current?.showing.close()
        let showing = VideoShowing(pool: pool, spinnerDelay: spinnerDelay)
        current = (pool, showing)
        return showing
    }
}

/// Draws one `VideoShowing`: the still until the first frame, the player, the spinner, the
/// failed box. Passes the view's inputs and moments on to the showing.
private struct MediaVideoContent: View {
    let video: MediaVideo
    @ObservedObject var showing: VideoShowing
    let report: (String) -> Void

    var body: some View {
        let still = MediaVideoStill(thumbnailUrl: video.thumbnailUrl, blurHash: video.blurHash)
        let _ = bindCallbacks()
        ZStack {
            if showing.failure != nil {
                Color.black
                MediaVideoFailedBox()
            } else {
                if !video.bare {
                    showing.firstFrameShown ? video.groundAfterFirstFrame : mediaVideoBackdrop
                }
                if !showing.firstFrameShown {
                    video.stillView(still)
                }
                // Hidden until the first frame, also with controls: the still shows, not the
                // controller's black backdrop, and the controls come on top with the frame (OD-7).
                if let player = showing.player {
                    playerView(player)
                        .opacity(showing.firstFrameShown ? 1 : 0)
                }
                if showing.showSpinner {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
        }
        .clipped()
        .onAppear { showing.show(video.spec(url: video.url, key: video.playerKey)) }
        .onDisappear { showing.close() }
        // The new spec comes in the argument: the closure may still see the old properties.
        .onChange(of: video.spec(url: video.url, key: video.playerKey)) { showing.show($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if video.pausesInBackground { showing.setAppActive(false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if video.pausesInBackground { showing.setAppActive(true) }
        }
    }

    /// Keeps the latest closures, so a parent passing new ones for the same URL is heard. Only a
    /// cause the author can fix is health: network, timeout and 5xx report nothing.
    private func bindCallbacks() {
        showing.onFirstFrame = video.onFirstFrame
        showing.onReady = video.onReady
        showing.onEnded = video.onEnded
        let onFailure = video.onFailure
        showing.onFailure = { [report] failure in
            let cause: String? = switch failure {
            case .invalidURL: "invalid_url"
            case let .player(cause): mediaFailureCause(videoFailure: cause)
            }
            if let cause { report(cause) }
            onFailure?()
        }
    }

    @ViewBuilder
    private func playerView(_ player: DigiaVideoPlayer) -> some View {
        if video.showControls {
            MediaPlayerControllerView(player: player.avPlayer, gravity: video.fit.videoGravity) { showing.frameShown() }
        } else {
            MediaPlayerLayerView(player: player, gravity: video.fit.videoGravity) { showing.frameShown() }
        }
    }
}

/// `main`'s native controls (`AVPlayerViewController`, as canvas and nudge video drew them).
/// Reports when the video is ready to display, which is the first frame.
private struct MediaPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let onReadyForDisplay: () -> Void

    final class Coordinator {
        var readyObserver: NSKeyValueObservation?
        weak var boundItem: AVPlayerItem?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.view.backgroundColor = .black
        controller.showsPlaybackControls = true
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.videoGravity = gravity
        guard controller.player !== player || context.coordinator.boundItem !== player.currentItem else { return }
        context.coordinator.boundItem = player.currentItem
        controller.player = nil
        controller.player = player
        context.coordinator.readyObserver = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { _, change in
            guard change.newValue == true else { return }
            Task { @MainActor in onReadyForDisplay() }
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.readyObserver?.invalidate()
        coordinator.readyObserver = nil
        controller.player = nil
    }
}

/// The view's own backing `AVPlayerLayer`, attached to the engine player (`attach(layer:)`, one
/// per view), so the video animates with the view's frame (PIP and floater expand and collapse).
/// Reports when that layer is ready to display, which is this view's first frame.
private struct MediaPlayerLayerView: UIViewRepresentable {
    let player: DigiaVideoPlayer
    let gravity: AVLayerVideoGravity
    let onReadyForDisplay: () -> Void

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.apply(player: player, gravity: gravity, onReady: onReadyForDisplay)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.apply(player: player, gravity: gravity, onReady: onReadyForDisplay)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.detach()
    }
}

final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
    private weak var video: DigiaVideoPlayer?
    private var readyObserver: NSKeyValueObservation?
    private var onReady: (() -> Void)?

    func apply(player: DigiaVideoPlayer, gravity: AVLayerVideoGravity, onReady: @escaping () -> Void) {
        guard let playerLayer else { return }
        self.onReady = onReady
        playerLayer.videoGravity = gravity
        guard video !== player || playerLayer.player !== player.avPlayer else { return }
        detach()
        video = player
        // The engine re-attaches its layers when the player is given another item, so
        // readiness, and so the first frame, is the new item's.
        player.attach(layer: playerLayer)
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.onReady?() }
        }
    }

    func detach() {
        readyObserver?.invalidate()
        readyObserver = nil
        playerLayer?.player = nil
        video = nil
    }
}
