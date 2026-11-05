import AVFoundation
import AVKit
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
/// default on every surface (OD-16). The #1A1A1A backdrop is only the loading ground before the
/// first frame. The floating window passes its own transparent ground.
///
/// Callbacks (the same set on every stack): `onFirstFrame` once per opened URL (again after a
/// handover to a new holder), `onEnded` when playback reaches the end and isn't looping,
/// `onFailure` after health is reported.
///
/// Story surfaces (T8) also use: `startMs`, where an opened player is put (nil keeps the pool's
/// playhead, so a remount resumes); `onReady`, the player at its first frame (the story reads
/// its playhead); `onLost`, a keyed borrow that was refused or a holder that was evicted, which
/// says nothing about the video.
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
    var groundAfterFirstFrame: Color = .black
    var playerKey: String? = nil
    var poolPriority: PoolPriority = .onScreen
    var startMs: Int64? = nil
    var onFirstFrame: (() -> Void)? = nil
    var onReady: ((AVPlayer) -> Void)? = nil
    var onLost: (() -> Void)? = nil
    var onEnded: (() -> Void)? = nil
    var onFailure: (() -> Void)? = nil
    /// How long a bare backdrop waits for the first frame before showing a spinner. Tests
    /// lengthen it to capture the backdrop alone.
    var spinnerDelay: TimeInterval = MediaVideo.defaultSpinnerDelay

    static let defaultSpinnerDelay: TimeInterval = 0.4

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var services
    @StateObject private var playback = MediaVideoPlayback()

    var body: some View {
        let still = MediaVideoStill(thumbnailUrl: thumbnailUrl, blurHash: blurHash)
        let _ = playback.updateCallbacks(
            onFirstFrame: onFirstFrame, onEnded: onEnded, onFailure: onFailure, onReady: onReady, onLost: onLost)
        ZStack {
            if playback.failed {
                Color.black
                MediaVideoFailedBox()
            } else {
                playback.firstFrameShown ? groundAfterFirstFrame : mediaVideoBackdrop
                if !playback.firstFrameShown {
                    stillView(still)
                }
                // Hidden until the first frame, also with controls: the still shows, not the
                // controller's black backdrop, and the controls come on top with the frame (OD-7).
                if let player = playback.player {
                    playerView(player)
                        .opacity(playback.firstFrameShown ? 1 : 0)
                }
                if playback.spinnerVisible {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
            }
        }
        .clipped()
        .onAppear { open(url: url, key: playerKey) }
        .onDisappear { playback.close() }
        // The new value comes in the argument: the closure may still see the old properties.
        .onChange(of: url) { open(url: $0, key: playerKey) }
        .onChange(of: playerKey) { open(url: url, key: $0) }
        .onChange(of: muted) { playback.player?.isMuted = $0 }
        .onChange(of: volume) { playback.player?.volume = $0 }
        .onChange(of: autoplay) { playback.setPlaying($0) }
        .onChange(of: loop) { playback.loop = $0 }
    }

    @ViewBuilder
    private func playerView(_ player: AVPlayer) -> some View {
        if showControls {
            MediaPlayerControllerView(player: player, gravity: fit.videoGravity) { playback.noteFirstFrame() }
        } else {
            MediaPlayerLayerView(player: player, gravity: fit.videoGravity) { playback.noteFirstFrame() }
        }
    }

    private func open(url: String, key: String?) {
        let canShow = MediaVideoStill.canShow(thumbnailUrl: thumbnailUrl, blurHash: blurHash)
        playback.open(
            url: url, key: key, priority: poolPriority, loop: loop, muted: muted, volume: volume,
            autoplay: autoplay,
            startMs: startMs, spinnerDelay: canShow ? nil : spinnerDelay,
            services: services,
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

/// A remote item reads through the range cache (one download serves playback and the cache);
/// `file://` and URLs the cache scheme can't carry play directly.
@MainActor
func mediaVideoItem(for url: URL, loader: MediaResourceLoader) -> AVPlayerItem {
    if url.isFileURL { return AVPlayerItem(url: url) }
    return loader.playerItem(for: url) ?? AVPlayerItem(url: url)
}

/// One showing's player: leases it from the pool, watches its item, and publishes first frame
/// and failure. All on the main actor.
@MainActor
final class MediaVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var firstFrameShown = false
    @Published private(set) var failed = false
    @Published private(set) var spinnerVisible = false

    var loop = false
    private var onFirstFrame: (() -> Void)?
    private var onFailure: (() -> Void)?
    private var onEnded: (() -> Void)?
    private var onReady: ((AVPlayer) -> Void)?
    private var onLost: (() -> Void)?

    private var opened: (url: String, key: String?)?
    private var lease: (pool: VideoPlayerPool, key: String, priority: PoolPriority, eviction: UUID, own: Bool)?
    /// The pool key of this node when the surface gives none (OD-15), stable while it is mounted.
    private let ownKey = "media-video-\(UUID().uuidString)"
    private var report: (String) -> Void = { _ in }
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var spinnerTask: Task<Void, Never>?
    /// A `startMs` seek is waiting for the item to be ready, or on its way: the player starts once
    /// it lands, so it never plays on from where the pool left it, nor from 0.
    private var seekPending = false
    private var pendingStartMs: Int64?
    private var wantsPlaying = false

    /// Keeps the latest closures, so a parent passing new ones for the same URL is heard.
    func updateCallbacks(
        onFirstFrame: (() -> Void)?, onEnded: (() -> Void)?, onFailure: (() -> Void)?,
        onReady: ((AVPlayer) -> Void)? = nil, onLost: (() -> Void)? = nil
    ) {
        self.onFirstFrame = onFirstFrame
        self.onEnded = onEnded
        self.onFailure = onFailure
        self.onReady = onReady
        self.onLost = onLost
    }

    /// Starts showing `url`. Re-opening what is already open is a no-op; anything else frees
    /// the old player first.
    func open(
        url: String, key: String?, priority: PoolPriority, loop: Bool, muted: Bool, volume: Float,
        autoplay: Bool, startMs: Int64? = nil, spinnerDelay: TimeInterval?, services: MediaServices,
        report: @escaping (String) -> Void
    ) {
        if let opened, opened.url == url, opened.key == key { return }
        close()
        opened = (url, key)
        self.loop = loop
        self.report = report
        guard let parsed = mediaUsableURL(url) else {
            fail(cause: "invalid_url")
            return
        }
        let pool = services.videoPool
        let poolKey = key ?? ownKey
        // Refused (pool full, not on screen): the still stays and nothing is reported.
        guard let player = pool.borrow(key: poolKey, url: parsed, priority: priority) else {
            onLost?()
            return
        }
        let eviction = pool.observeEviction(of: poolKey) { [weak self] in self?.evicted() }
        lease = (pool, poolKey, priority, eviction, key == nil)
        player.isMuted = muted
        player.volume = volume
        player.actionAtItemEnd = .pause
        if let startMs {
            seekPending = true
            pendingStartMs = max(startMs, 0)
        }
        if let item = player.currentItem { watch(item) }
        self.player = player
        seekToStartIfReady()
        setPlaying(autoplay)
        if let spinnerDelay {
            spinnerTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(spinnerDelay * 1_000_000_000))
                guard let self, !Task.isCancelled, !self.firstFrameShown, !self.failed else { return }
                self.spinnerVisible = true
            }
        }
    }

    /// Issues the `startMs` seek once the item is ready (a seek on an item still loading lands
    /// nowhere), then starts the player if it should play.
    private func seekToStartIfReady() {
        guard let player, let startMs = pendingStartMs, player.currentItem?.status == .readyToPlay else { return }
        pendingStartMs = nil
        player.seek(to: CMTime(value: startMs, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.player === player, self.seekPending else { return }
                self.seekPending = false
                self.setPlaying(self.wantsPlaying)
            }
        }
    }

    func setPlaying(_ playing: Bool) {
        wantsPlaying = playing
        guard let player, !failed else { return }
        if playing, seekPending { return }
        if playing { player.play() } else { player.pause() }
    }

    /// Stops the player: gives it back to the pool, which keeps it for a remount, or destroys it
    /// when the key was this node's own (OD-15).
    func close() {
        let leaving = player
        unwatch()
        if let lease {
            lease.pool.removeEvictionObserver(lease.eviction, for: lease.key)
            if let leaving {
                if lease.own {
                    leaving.pause()
                    lease.pool.discard(key: lease.key, player: leaving)
                } else {
                    lease.pool.giveBack(key: lease.key, player: leaving, priority: lease.priority)
                }
            }
        }
        lease = nil
        player = nil
        opened = nil
        seekPending = false
        pendingStartMs = nil
        firstFrameShown = false
        failed = false
        spinnerVisible = false
    }

    func noteFirstFrame() {
        guard !firstFrameShown, !failed, let player else { return }
        firstFrameShown = true
        spinnerVisible = false
        spinnerTask?.cancel()
        onFirstFrame?()
        onReady?(player)
    }

    private func watch(_ item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            switch item.status {
            case .failed:
                Task { @MainActor in self?.fail(cause: mediaFailureCause(playerItem: item)) }
            case .readyToPlay:
                Task { @MainActor in self?.seekToStartIfReady() }
            default:
                break
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteEnded() }
        }
    }

    private func unwatch() {
        spinnerTask?.cancel()
        spinnerTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// The pool took the player back for a higher-ranked holder, or re-pointed it at another
    /// URL for another holder: show the still again. The showing stays opened, so it isn't
    /// re-borrowed every frame; it borrows again when it next opens.
    private func evicted() {
        unwatch()
        if let lease { lease.pool.removeEvictionObserver(lease.eviction, for: lease.key) }
        lease = nil
        player = nil
        firstFrameShown = false
        spinnerVisible = false
        onLost?()
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

    private weak var boundItem: AVPlayerItem?

    func apply(player: AVPlayer, gravity: AVLayerVideoGravity, onReady: @escaping () -> Void) {
        guard let playerLayer else { return }
        self.onReady = onReady
        playerLayer.videoGravity = gravity
        // A pooled player re-pointed at a new URL keeps the old frame ready: re-attach it so
        // readiness, and so the first frame, is the new item's.
        guard playerLayer.player !== player || boundItem !== player.currentItem else { return }
        boundItem = player.currentItem
        playerLayer.player = nil
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
