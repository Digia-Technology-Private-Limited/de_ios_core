import AVFoundation
import SwiftUI
import UIKit

internal import DigiaMediaCache

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
/// else the dark backdrop. No frame is cut from the video.
enum MediaVideoStill: Equatable {
    case thumbnail(String)
    case blurHash(String)
    case backdrop

    init(thumbnailUrl: String?, blurHash: String?) {
        if let thumbnailUrl, mediaUsableURL(thumbnailUrl) != nil {
            self = .thumbnail(thumbnailUrl)
        } else if let blurHash, !blurHash.isEmpty {
            self = .blurHash(blurHash)
        } else {
            self = .backdrop
        }
    }

    /// Only a bare backdrop earns a spinner: a thumbnail or a BlurHash is better to look at.
    var allowsSpinner: Bool { self == .backdrop }
}

/// The one video wrapper every surface renders through. Flat parameters, like `MediaImage`.
///
/// Until the first frame it shows the still (`MediaVideoStill`). A spinner appears only over the
/// bare backdrop, after `spinnerDelay` (~400 ms) with no first frame. When the video can't load (or the URL
/// is unusable) it shows the "Video failed" box, the same box `main`'s nudge video showed, and
/// reports health once: `invalid_url`, `http_4xx` or `decode`. A network failure, a timeout or a
/// 5xx reports nothing. Never throws from the render path.
///
/// Remote items read through the range cache (`MediaServices.videoLoader`); `file://` plays
/// directly. The wrapper owns its own player; `playerKey` names the player a surface wants to
/// keep across remounts (used once players come from the pool).
struct MediaVideo: View {
    let url: String
    var fit: MediaFit = .cover
    var thumbnailUrl: String? = nil
    var blurHash: String? = nil
    var loop: Bool = true
    var muted: Bool = true
    var autoplay: Bool = true
    var playerKey: String? = nil
    /// The first frame drew.
    var onFirstFrame: (() -> Void)? = nil
    /// The video can't play (health is already reported).
    var onFailure: (() -> Void)? = nil
    /// Playback reached the end (not called while looping).
    var onEnded: (() -> Void)? = nil
    /// How long a bare backdrop waits for the first frame before showing a spinner. Tests
    /// lengthen it to capture the backdrop alone.
    var spinnerDelay: TimeInterval = MediaVideo.defaultSpinnerDelay

    static let defaultSpinnerDelay: TimeInterval = 0.4

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @StateObject private var playback = MediaVideoPlayback()

    var body: some View {
        let still = MediaVideoStill(thumbnailUrl: thumbnailUrl, blurHash: blurHash)
        ZStack {
            Color.black
            if !playback.firstFrameShown {
                stillView(still)
            }
            if let player = playback.player, !playback.failed {
                MediaPlayerLayerView(player: player, gravity: fit.videoGravity) {
                    playback.noteFirstFrame()
                }
                .opacity(playback.firstFrameShown ? 1 : 0)
            }
            if playback.failed {
                MediaVideoFailedBox()
            } else if playback.spinnerVisible {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
        .clipped()
        .onAppear { open(still: still) }
        .onDisappear { playback.close() }
        .onChange(of: url) { _ in open(still: still) }
        .onChange(of: muted) { playback.player?.isMuted = $0 }
    }

    private func open(still: MediaVideoStill) {
        playback.onFirstFrame = onFirstFrame
        playback.onFailure = onFailure
        playback.onEnded = onEnded
        playback.open(
            url: url, loop: loop, muted: muted, autoplay: autoplay, spinnerDelay: still.allowsSpinner ? spinnerDelay : nil,
            loader: services.videoLoader,
            report: { [services, campaignKey] cause in services.reportHealth(campaignKey, .video, cause) })
    }

    @ViewBuilder
    private func stillView(_ still: MediaVideoStill) -> some View {
        switch still {
        case let .thumbnail(thumbnail):
            MediaImage(url: thumbnail, fit: fit, blurHash: blurHash)
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

/// One showing's player: builds it, watches its item, and publishes first frame and failure.
/// All on the main actor.
@MainActor
final class MediaVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var firstFrameShown = false
    @Published private(set) var failed = false
    @Published private(set) var spinnerVisible = false

    var onFirstFrame: (() -> Void)?
    var onFailure: (() -> Void)?
    var onEnded: (() -> Void)?

    private var openedURL: String?
    private var loop = true
    private var report: (String) -> Void = { _ in }
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var spinnerTask: Task<Void, Never>?

    /// Starts showing `url`. Re-opening the URL already open is a no-op; a new URL frees the
    /// old player first.
    func open(
        url: String, loop: Bool, muted: Bool, autoplay: Bool, spinnerDelay: TimeInterval?,
        loader: MediaResourceLoader, report: @escaping (String) -> Void
    ) {
        guard url != openedURL else { return }
        close()
        openedURL = url
        self.loop = loop
        self.report = report
        guard let parsed = mediaUsableURL(url) else {
            fail(cause: "invalid_url")
            return
        }
        let item = Self.item(for: parsed, loader: loader)
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in self?.fail(cause: mediaFailureCause(playerItem: item)) }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteEnded() }
        }
        self.player = player
        if autoplay { player.play() }
        if let spinnerDelay {
            spinnerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(spinnerDelay * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.firstFrameShown, !self.failed else { return }
                self.spinnerVisible = true
            }
        }
    }

    /// Stops and frees the player.
    func close() {
        spinnerTask?.cancel()
        spinnerTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        openedURL = nil
        firstFrameShown = false
        failed = false
        spinnerVisible = false
    }

    func noteFirstFrame() {
        guard !firstFrameShown, !failed, player != nil else { return }
        firstFrameShown = true
        spinnerVisible = false
        spinnerTask?.cancel()
        onFirstFrame?()
    }

    /// Shows the failed box once per opened URL. Only a cause the author can fix is health: a
    /// nil cause (network, timeout, 5xx) reports nothing.
    private func fail(cause: String?) {
        guard !failed else { return }
        failed = true
        spinnerVisible = false
        spinnerTask?.cancel()
        player?.pause()
        if let cause { report(cause) }
        onFailure?()
    }

    private func noteEnded() {
        guard let player else { return }
        if loop {
            player.seek(to: .zero)
            player.play()
        } else {
            onEnded?()
        }
    }

    /// Range-cache-backed for remote URLs (one download serves playback and the cache), direct
    /// for `file://` and for URLs the cache scheme can't carry.
    private static func item(for url: URL, loader: MediaResourceLoader) -> AVPlayerItem {
        if url.isFileURL { return AVPlayerItem(url: url) }
        return loader.playerItem(for: url) ?? AVPlayerItem(url: url)
    }
}

/// The `AVPlayerLayer` a video draws into. Reports when the layer is ready to display, which is
/// the first frame.
private struct MediaPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
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

private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var readyObserver: NSKeyValueObservation?
    private var onReady: (() -> Void)?

    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    func apply(player: AVPlayer, gravity: AVLayerVideoGravity, onReady: @escaping () -> Void) {
        guard let playerLayer else { return }
        self.onReady = onReady
        playerLayer.videoGravity = gravity
        guard playerLayer.player !== player else { return }
        playerLayer.player = player
        readyObserver = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.onReady?() }
        }
    }

    func detach() {
        readyObserver?.invalidate()
        readyObserver = nil
        playerLayer?.player = nil
    }
}
