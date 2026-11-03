import AVFoundation
import SwiftUI
import UIKit

/// The process-wide loader every D2 (range-cache) player item reads through. One instance for
/// the process, like `MediaRangeCacheStore.shared()`: a pooled item outlives any single view,
/// so the resource-loader delegate behind its asset must never be a per-view object that can
/// deallocate mid-playback (AVURLAsset holds the delegate weakly). Tests inject their own
/// loader (backed by a fake store) through the coordinator instead of touching this.
internal enum SharedMediaResourceLoader {
    nonisolated(unsafe) static let shared = MediaResourceLoader()
}

extension MediaFit {
    /// The `AVPlayerLayer` gravity matching this fit: cover crops, contain letterboxes, fill
    /// stretches (the author's explicit stretch, as in the pre-rewire canvas mapping).
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .cover: .resizeAspectFill
        case .contain: .resizeAspect
        case .fill: .resize
        }
    }
}

/// The cause for a failed `AVPlayerItem`, for `media_load_failed`. The shared
/// `mediaFailureCause(playerItem:)` maps author-fixable faults (HTTP 4xx, undecodable codec).
/// Anything else that fails an item (transport loss, 5xx, unknown) reports `network` — the
/// iOS-wide rule (lane C, plan-directed) that every failure carries a non-nil cause, an
/// intended difference from Android's author-fixable-only contract.
internal func mediaVideoFailureCause(item: AVPlayerItem) -> String? {
    mediaFailureCause(playerItem: item)
        ?? mediaVideoDecoderCause(error: item.error)
        ?? "network"
}

/// Decoder exhaustion (`AVErrorDecoderTemporarilyUnavailable`, -11839: too many live decoders
/// on a low-end phone) is a device fault, not a silent hole, so it maps to `decode`. Pure, so
/// the mapping is unit-testable without a failing player item.
internal func mediaVideoDecoderCause(error: (any Error)?) -> String? {
    if (error as? AVError)?.code == .decoderTemporarilyUnavailable {
        return "decode"
    }
    return nil
}

extension AVPlayer {
    /// The obtain-side reset/take-over protocol (Android `Player.takeOver` in spirit, iOS in
    /// shape): whoever shows a player applies the whole spec before the first frame, so the
    /// next borrower inherits nothing — item, loop flag, volume, playhead and play state are
    /// all set here, unconditionally. Nothing is restored on `giveBack`; the next `takeOver`
    /// resets everything the SDK touches.
    ///
    /// A handover under the same URL skips the item swap (the player already holds this
    /// origin through the range cache, so there is nothing to re-buffer — the borrowed frame
    /// survives) but still resets loop, volume and the playhead and still applies autoplay.
    /// `file://` items play directly, never cached (scheme-routing, as on Android).
    ///
    /// `setLooping` carries the loop flag to its owner: the pool entry for a borrowed player,
    /// a local `AVPlayerLooper` for an owned one. Never throws: an unusable URL reports
    /// through `onInvalidStart` (the caller degrades + reports `invalid_url`) and leaves the
    /// current item alone.
    internal func takeOver(
        spec: VideoSpec,
        resourceLoader: MediaResourceLoader,
        setLooping: (Bool) -> Void,
        onInvalidStart: () -> Void
    ) {
        guard let url = mediaUsableURL(spec.url) else {
            onInvalidStart()
            return
        }
        if !holdsOrigin(url) {
            replaceCurrentItem(with: Self.cachedItem(for: url, via: resourceLoader))
        }
        setLooping(spec.playback.loop)
        volume = spec.playback.volume
        isMuted = spec.playback.muted
        seek(
            to: CMTime(value: Int64(max(spec.playback.startMs, 0)), timescale: 1_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        if spec.playback.autoplay {
            play()
        } else {
            pause()
        }
    }

    /// Whether the current item already serves this origin through the range cache (or
    /// directly, for `file://`). A plain remote item the pool just re-pointed at the same URL
    /// does NOT count: it would stream around the cache, so it is always swapped below.
    private func holdsOrigin(_ url: URL) -> Bool {
        guard let assetURL = (currentItem?.asset as? AVURLAsset)?.url else { return false }
        if assetURL.scheme == MediaResourceLoader.scheme {
            return MediaResourceLoader.originURL(from: assetURL) == url
        }
        // Only file:// plays directly (scheme-routing, as on Android): the same file means
        // nothing to re-buffer.
        return url.isFileURL && assetURL == url
    }

    /// The item a take-over installs: range-cache-backed for remote URLs (one download serves
    /// playback and caching, D2), direct for `file://` and for URLs the private scheme cannot
    /// represent (degrade, never throw).
    fileprivate static func cachedItem(for url: URL, via loader: MediaResourceLoader) -> AVPlayerItem {
        if url.isFileURL {
            return AVPlayerItem(url: url)
        }
        if let item = loader.playerItem(for: url) {
            return item
        }
        return AVPlayerItem(url: url)
    }
}

/// Owns one `MediaVideo` borrow: obtain on appear, `takeOver` before the first frame,
/// `giveBack` on disappear, release of the owned fallback on disappear or URL change.
///
/// Borrowed (keep-alive key + pool): a refused borrow (pool full of higher ranks) or an
/// eviction observed mid-show (the pool detaches the item; `currentItem` KVO goes nil)
/// degrades to the still — never an owned player around the pool (D3). Keyless (nudge,
/// canvas) builds and owns its player outright. An externally supplied player is driven in
/// place and never paused, released or given back.
///
/// Never throws from the render path: every failure (bad URL, item failure, eviction) lands
/// on the still below plus a health event with a non-nil cause, never a raise.
@MainActor
internal final class MediaVideoCoordinator: ObservableObject {
    @Published private(set) var activePlayer: AVPlayer?
    @Published private(set) var firstFrame = false
    @Published private(set) var failed = false
    @Published private(set) var degraded = false
    @Published private(set) var showSpinner = false

    /// The player layer draws while a borrow (or owned player) is live and healthy.
    var showPlayer: Bool { activePlayer != nil && !degraded && !failed }
    /// The borrow fell back to its still for good: failed, evicted, or refused.
    var gaveUp: Bool { failed || degraded || (usesPool && activePlayer == nil) }

    private let key: String?
    private let poolPriority: PoolPriority
    private let poolOverride: VideoPlayerPool?
    private let loader: MediaResourceLoader
    private let factory: any PlayerFactory
    private var pool: VideoPlayerPool?
    private var services = MediaServices.unconfigured
    private var usesPool = false
    private var externalPlayer: AVPlayer?
    private var holdingKey: String?
    private var ownedPlayer: AVQueuePlayer?
    private var ownedLooper: AVPlayerLooper?
    private var attachedPlayer: AVPlayer?
    private var lastURL: String?
    private var startMs: Int = 0
    private var campaignKey: String?
    private var readyFired = false
    private var gaveUpFired = false
    private var onReady: ((AVPlayer) -> Void)?
    private var onError: ((String) -> Void)?
    private var onGiveUp: (() -> Void)?
    private var spinnerTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var failObserver: NSObjectProtocol?

    internal init(
        keepAliveKey: String? = nil,
        poolPriority: PoolPriority = .onScreen,
        pool: VideoPlayerPool? = nil,
        resourceLoader: MediaResourceLoader? = nil,
        factory: (any PlayerFactory)? = nil
    ) {
        self.key = keepAliveKey
        self.poolPriority = poolPriority
        self.poolOverride = pool
        self.loader = resourceLoader ?? SharedMediaResourceLoader.shared
        self.factory = factory ?? DefaultPlayerFactory()
    }

    /// Supplies an externally owned player (mirrors Android's `player` param): the pool is
    /// skipped, but the reset protocol still applies.
    func useExternalPlayer(_ player: AVPlayer?) {
        externalPlayer = player
    }

    /// Starts showing `spec`: borrows or builds the player, takes it over, arms observers.
    /// A spec change while visible re-takes-over (the same player for a borrowed handover, a
    /// fresh player for an owned URL change — a released player is never reused).
    func appear(
        spec: VideoSpec,
        playing: Bool,
        campaignKey: String?,
        services: MediaServices = .unconfigured,
        onReady: ((AVPlayer) -> Void)? = nil,
        onError: ((String) -> Void)? = nil,
        onGiveUp: (() -> Void)? = nil
    ) {
        self.campaignKey = campaignKey
        self.services = services
        self.onReady = onReady
        self.onError = onError
        self.onGiveUp = onGiveUp
        pool = poolOverride ?? services.pool()
        usesPool = key != nil && externalPlayer == nil && pool != nil
        let urlChanged = lastURL != nil && lastURL != spec.url
        lastURL = spec.url
        startMs = spec.playback.startMs
        if let externalPlayer {
            attach(externalPlayer, spec: spec)
            setPlaying(playing)
            return
        }
        if usesPool {
            guard let key, let pool else {
                noteGaveUp()
                return
            }
            guard let url = mediaUsableURL(spec.url) else {
                degradeToStill(cause: "invalid_url")
                return
            }
            guard let borrowed = pool.obtain(key: key, url: url, priority: poolPriority) else {
                activePlayer = nil
                noteGaveUp()
                armSpinner(spec: spec)
                return
            }
            holdingKey = key
            attach(borrowed, spec: spec, pool: pool, poolKey: key)
            setPlaying(playing)
            return
        }
        if ownedPlayer == nil || urlChanged {
            releaseOwned()
            let fresh = factory.makePlayer()
            ownedPlayer = fresh
            attach(fresh, spec: spec, owned: fresh)
        } else if let owned = ownedPlayer {
            attach(owned, spec: spec, owned: owned)
        }
        setPlaying(playing)
    }

    /// Drives play/pause without re-taking-over (so a visibility toggle never re-seeks the
    /// playhead).
    func setPlaying(_ playing: Bool) {
        guard let player = activePlayer, !degraded, !failed else { return }
        if playing {
            player.play()
        } else {
            player.pause()
        }
    }

    /// Applies a mute toggle without re-taking-over (so it never re-seeks the playhead).
    func setMuted(_ muted: Bool) {
        activePlayer?.isMuted = muted
    }

    /// Gives back the borrow (a missing key — evicted or released — is a silent no-op) and
    /// releases the owned fallback. An external player is only detached, never touched.
    func disappear() {
        spinnerTask?.cancel()
        spinnerTask = nil
        degraded = false
        gaveUpFired = false
        if let key = holdingKey {
            pool?.giveBack(key: key)
            holdingKey = nil
        }
        detachObservers()
        activePlayer = nil
        attachedPlayer = nil
        releaseOwned()
    }

    // MARK: - Private

    private func attach(
        _ player: AVPlayer,
        spec: VideoSpec,
        pool: VideoPlayerPool? = nil,
        poolKey: String? = nil,
        owned: AVQueuePlayer? = nil
    ) {
        // Take over first so the observers below attach to the item that will actually play;
        // a same-URL handover keeps the item (no re-buffer, no gap).
        if attachedPlayer !== player {
            detachObservers()
            attachedPlayer = player
            activePlayer = player
        }
        firstFrame = false
        failed = false
        readyFired = false
        player.takeOver(
            spec: spec,
            resourceLoader: loader,
            setLooping: { [weak self, weak pool, weak owned] looping in
                guard let self else { return }
                if let pool, let poolKey {
                    pool.setLooping(looping, forKey: poolKey)
                } else if let owned {
                    self.ownedLooper = nil
                    if looping, let item = owned.currentItem {
                        self.ownedLooper = AVPlayerLooper(player: owned, templateItem: item)
                    }
                } else if let queue = player as? AVQueuePlayer {
                    self.ownedLooper = nil
                    if looping, let item = queue.currentItem {
                        self.ownedLooper = AVPlayerLooper(player: queue, templateItem: item)
                    }
                }
            },
            onInvalidStart: { [weak self] in
                self?.degradeToStill(cause: "invalid_url")
            }
        )
        observe(player: player)
        armSpinner(spec: spec)
        noteGaveUp()
    }

    private func observe(player: AVPlayer) {
        detachObservers()
        statusObserver = player.currentItem?.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor in self?.noteItemStatus(item) }
        }
        itemObserver = player.observe(\.currentItem, options: [.old, .new]) {
            [weak self] _, change in
            Task { @MainActor in self?.noteCurrentItem(
                old: change.oldValue as? AVPlayerItem,
                new: change.newValue as? AVPlayerItem
            ) }
        }
        let startSeconds = Double(max(startMs, 0)) / 1_000
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if time.seconds.isFinite, time.seconds >= startSeconds {
                    self.noteFirstFrame()
                }
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteItemFailed() }
        }
    }

    private func noteItemStatus(_ item: AVPlayerItem) {
        guard item === attachedPlayer?.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            noteFirstFrame()
        case .failed:
            noteItemFailed(item: item)
        default:
            break
        }
    }

    /// A `nil` item we did not clear ourselves means the borrow is gone — except when the
    /// queue advanced past a failed item (`AVQueuePlayer`, which the pool vends for looping,
    /// detaches a failed item instead of holding it at `.failed`): the detached item's own
    /// status decides. A genuine detach degrades to the still, never blank; a failure reports
    /// with its cause, exactly as if the status observer had caught it first.
    private func noteCurrentItem(old: AVPlayerItem?, new: AVPlayerItem?) {
        if let old, new == nil, old.status == .failed {
            noteItemFailed(item: old)
            return
        }
        if new == nil, attachedPlayer != nil, activePlayer != nil {
            degraded = true
            activePlayer = nil
            noteGaveUp()
        }
    }

    private func noteFirstFrame() {
        guard !firstFrame, !failed else { return }
        guard attachedPlayer?.currentItem?.status == .readyToPlay else { return }
        firstFrame = true
        showSpinner = false
        spinnerTask?.cancel()
        if !readyFired, let player = activePlayer {
            readyFired = true
            onReady?(player)
        }
    }

    private func noteItemFailed() {
        guard let item = attachedPlayer?.currentItem else { return }
        noteItemFailed(item: item)
    }

    private func noteItemFailed(item: AVPlayerItem) {
        guard !failed else { return }
        failed = true
        showSpinner = false
        spinnerTask?.cancel()
        let cause = mediaVideoFailureCause(item: item)
        services.reportHealth(campaignKey, .video, cause)
        if let cause {
            onError?(cause)
        }
        noteGaveUp()
    }

    private func degradeToStill(cause: String) {
        if let key = holdingKey {
            pool?.giveBack(key: key)
            holdingKey = nil
        }
        failed = true
        showSpinner = false
        spinnerTask?.cancel()
        activePlayer = nil
        services.reportHealth(campaignKey, .video, cause)
        onError?(cause)
        noteGaveUp()
    }

    private func noteGaveUp() {
        guard gaveUp, !gaveUpFired else { return }
        gaveUpFired = true
        spinnerTask?.cancel()
        onGiveUp?()
    }

    private func armSpinner(spec: VideoSpec) {
        spinnerTask?.cancel()
        showSpinner = false
        let nothingBetter = spec.posterURL == nil && spec.blurHash == nil
        guard showPlayer, nothingBetter, !firstFrame, !failed else { return }
        spinnerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(MediaImage.spinnerDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.showPlayer, !self.firstFrame, !self.failed {
                self.showSpinner = true
            }
        }
    }

    private func detachObservers() {
        statusObserver?.invalidate()
        itemObserver?.invalidate()
        if let timeObserver, let player = attachedPlayer {
            player.removeTimeObserver(timeObserver)
        }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        statusObserver = nil
        itemObserver = nil
        timeObserver = nil
        failObserver = nil
    }

    private func releaseOwned() {
        detachObservers()
        if let owned = ownedPlayer {
            owned.pause()
            owned.replaceCurrentItem(with: nil)
        }
        ownedLooper = nil
        ownedPlayer = nil
    }
}

/// The one video wrapper every surface renders through (D1): poster before the first frame,
/// BlurHash under that, the shared dark backdrop at the bottom (D5: the bottom layer is never
/// empty), a spinner only after `MediaImage.spinnerDelaySeconds` with nothing better to show.
///
/// With `keepAliveKey` the player is borrowed from the per-SDK-instance `VideoPlayerPool`
/// (`obtain` on appear, `giveBack` on disappear): rebuilds (rotation, PIP drag) keep playing
/// without restarting. A refused borrow or an evicted holder renders the still — never an
/// owned player around the pool (D3). Without a key the view owns its player outright
/// (nudge, canvas). An externally supplied `player` is driven in place (reset via the same
/// take-over) and never paused, released or given back.
///
/// The borrowed frame is transparent until the first frame; the campaign poster (through
/// `MediaImage`), BlurHash and backdrop show through until then. Every failure degrades to
/// the still with a health event carrying a non-nil cause — decoder exhaustion included —
/// never a throw, never an empty box.
///
/// Reads the campaign attribution (`digiaCampaignKey`) set by the hosting surface, like
/// `MediaImage` does: the wrapper knows nothing about campaigns (R-C), it only passes the
/// key to health reporting.
internal struct MediaVideo: View {
    let spec: VideoSpec
    var keepAliveKey: String? = nil
    var poolPriority: PoolPriority = .onScreen
    var playing: Bool = true
    var player: AVPlayer? = nil
    /// Test seam: the pool to borrow from. Production leaves nil to read the SDK instance's.
    var pool: VideoPlayerPool? = nil
    /// Test seam: the D2 loader items read through. Production leaves nil for the shared one.
    var resourceLoader: MediaResourceLoader? = nil
    var onReady: ((AVPlayer) -> Void)? = nil
    /// The failure. The argument is the same non-nil cause sent to health.
    var onError: ((String) -> Void)? = nil
    var onGiveUp: (() -> Void)? = nil

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var mediaServices
    @StateObject private var coordinator: MediaVideoCoordinator
    private let blurStill: UIImage?

    init(
        spec: VideoSpec,
        keepAliveKey: String? = nil,
        poolPriority: PoolPriority = .onScreen,
        playing: Bool = true,
        player: AVPlayer? = nil,
        pool: VideoPlayerPool? = nil,
        resourceLoader: MediaResourceLoader? = nil,
        onReady: ((AVPlayer) -> Void)? = nil,
        onError: ((String) -> Void)? = nil,
        onGiveUp: (() -> Void)? = nil
    ) {
        self.spec = spec
        self.keepAliveKey = keepAliveKey
        self.poolPriority = poolPriority
        self.playing = playing
        self.player = player
        self.pool = pool
        self.resourceLoader = resourceLoader
        self.onReady = onReady
        self.onError = onError
        self.onGiveUp = onGiveUp
        _coordinator = StateObject(wrappedValue: MediaVideoCoordinator(
            keepAliveKey: keepAliveKey,
            poolPriority: poolPriority,
            pool: pool,
            resourceLoader: resourceLoader
        ))
        self.blurStill = spec.blurHash.flatMap { BlurHashDecoder.decode($0, width: 32, height: 32) }
    }

    var body: some View {
        ZStack {
            Color.mediaBackdrop
            if let blurStill {
                if let mode = spec.fit.contentMode {
                    Image(uiImage: blurStill)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                } else {
                    Image(uiImage: blurStill)
                        .resizable()
                }
            }
            if !coordinator.firstFrame, !coordinator.failed,
               let posterURL = spec.posterURL, !posterURL.isEmpty
            {
                MediaImage(spec: ImageSpec(url: posterURL, fit: spec.fit))
            }
            if coordinator.showPlayer, let active = coordinator.activePlayer {
                MediaPlayerLayerView(player: active, gravity: spec.fit.videoGravity)
            }
            if coordinator.showSpinner {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            coordinator.useExternalPlayer(player)
            coordinator.appear(
                spec: spec,
                playing: playing,
                campaignKey: campaignKey,
                services: mediaServices,
                onReady: onReady,
                onError: onError,
                onGiveUp: onGiveUp
            )
        }
        .onDisappear {
            coordinator.disappear()
        }
        .onChange(of: spec.url) { _ in
            coordinator.appear(
                spec: spec,
                playing: playing,
                campaignKey: campaignKey,
                services: mediaServices,
                onReady: onReady,
                onError: onError,
                onGiveUp: onGiveUp
            )
        }
        .onChange(of: spec.playback.muted) { _ in
            coordinator.setMuted(spec.playback.muted)
        }
        .onChange(of: playing) { _ in
            coordinator.setPlaying(playing)
        }
    }
}

/// The `AVPlayerLayer`-backed view a `MediaVideo` frame draws into: transparent until the
/// first frame, so the poster/BlurHash/backdrop below show through.
private struct MediaPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> PlayerBackedView {
        let view = PlayerBackedView()
        view.apply(player: player, gravity: gravity)
        return view
    }

    func updateUIView(_ view: PlayerBackedView, context: Context) {
        view.apply(player: player, gravity: gravity)
    }
}

private final class PlayerBackedView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    func apply(player: AVPlayer, gravity: AVLayerVideoGravity) {
        guard let playerLayer = layer as? AVPlayerLayer else { return }
        playerLayer.player = player
        playerLayer.videoGravity = gravity
    }
}
