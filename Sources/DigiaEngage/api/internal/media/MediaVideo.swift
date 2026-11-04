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

/// Owns one `MediaVideo` showing (D16): the ONLY code that sets volume, mute,
/// play, pause, seek and loop for this showing — through the lease, the
/// take-over in `open()` and its own `play()`/`pause()`/`setMuted(_)`/
/// `seekToStart()` methods, which the `playing`/`spec` inputs below drive. The
/// drawing half, `MediaVideo(state:)`, only attaches the surface and draws the
/// D14 layers — it calls no playback method.
///
/// Owns the lease: obtained on appear (SDK pool, or the no-SDK fallback pool
/// when the SDK is not initialized), released on disappear and in `deinit`.
/// A keyless showing (nudge, canvas) builds and owns its player outright. An
/// externally supplied player is driven in place and never paused, released
/// or given back.
///
/// First-mount rules kept exactly (take-over is untouched): a handover-from-
/// rail starts at 0 with sound; a same-key remount resumes (the item is kept,
/// the take-over re-applies the window); a replay/revisit-after-completion
/// starts at 0; handover/PIP mounts never re-prepare (same URL skips the item
/// swap) and never restart loading.
///
/// Never throws from the render path: every failure (bad URL, item failure,
/// eviction, refused borrow) lands on the still below plus a health event with
/// a non-nil cause, never a raise.
///
/// Publishes its playhead from the start: `firstFrameShown`, `positionMs`,
/// `durationMs`, `ended`, `failed`, `degraded` — so story drivers read the
/// state instead of the raw player.
@MainActor
internal final class MediaVideoState: ObservableObject {
    @Published private(set) var activePlayer: AVPlayer?
    @Published private(set) var firstFrameShown = false
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var degraded = false
    @Published private(set) var showSpinner = false

    /// The player layer draws while a borrow (or owned player) is live and healthy.
    var showPlayer: Bool { activePlayer != nil && !degraded && !failed }
    /// The borrow fell back to its still for good: failed, evicted, or refused.
    var gaveUp: Bool { failed || degraded || (usesLease && activePlayer == nil) }

    /// The showing's spec. Set before appear; later sets apply live: a URL
    /// change re-opens the borrow (a released player is never reused), a
    /// mute-only change applies without re-seeking. Drawing-only changes just
    /// re-render. The view assigns this; it calls no playback method.
    var spec: VideoSpec {
        didSet {
            guard isAppeared, spec != oldValue else { return }
            if spec.url != oldValue.url {
                open()
            } else if spec.playback.muted != oldValue.playback.muted {
                applyMuted()
            }
        }
    }

    /// Whether the showing is told to play (pausing no longer needs an
    /// unmount). Assigned by the view/owner; the state drives the player.
    var playing: Bool {
        didSet {
            guard isAppeared, playing != oldValue else { return }
            if playing { play() } else { pause() }
        }
    }

    var onReady: ((AVPlayer) -> Void)?
    var onError: ((String) -> Void)?
    var onGiveUp: (() -> Void)?
    /// The borrow was handed to the viewer on tap (handover): the viewer's
    /// lease under the same key now owns the holder, so this dispose must not
    /// free it. Read fresh at dispose time. Default false keeps the
    /// rail-stays-mounted handover exactly as before.
    /// Read fresh at dispose time. `Sendable` so `deinit` (nonisolated) can
    /// consult it too; R2 owners pass a capture-free or snapshot read.
    var borrowHandedOver: @Sendable () -> Bool = { false }

    /// The poster still, decoded once per spec: drawn under the player layer.
    let blurStill: UIImage?

    private let key: String?
    private let poolPriority: PoolPriority
    private let poolOverride: VideoPlayerPool?
    private let loader: MediaResourceLoader
    private let factory: any PlayerFactory
    private var lease: PlayerLease?
    private var usesLease = false
    private var externalPlayer: AVPlayer?
    private var ownedPlayer: AVQueuePlayer?
    private var ownedLooper: AVPlayerLooper?
    private var attachedPlayer: AVPlayer?
    private var lastURL: String?
    private var startMs: Int = 0
    private var campaignKey: String?
    private var services = MediaServices.unconfigured
    private var isAppeared = false
    private var readyFired = false
    private var gaveUpFired = false
    private var spinnerTask: Task<Void, Never>?
    private var statusObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var failObserver: NSObjectProtocol?
    /// The item the status + failure observers track. The take-over item is not
    /// always the playing item: the pool's looping entry swaps it for an
    /// `AVPlayerLooper` replica once its duration loads (see `trackItem`).
    private var observedItem: AVPlayerItem?

    internal init(
        spec: VideoSpec,
        playing: Bool = true,
        keepAliveKey: String? = nil,
        poolPriority: PoolPriority = .onScreen,
        pool: VideoPlayerPool? = nil,
        resourceLoader: MediaResourceLoader? = nil,
        factory: (any PlayerFactory)? = nil,
        borrowHandedOver: @escaping @Sendable () -> Bool = { false },
        onReady: ((AVPlayer) -> Void)? = nil,
        onError: ((String) -> Void)? = nil,
        onGiveUp: (() -> Void)? = nil
    ) {
        self.spec = spec
        self.playing = playing
        self.key = keepAliveKey
        self.poolPriority = poolPriority
        self.poolOverride = pool
        self.loader = resourceLoader ?? SharedMediaResourceLoader.shared
        self.factory = factory ?? DefaultPlayerFactory()
        self.borrowHandedOver = borrowHandedOver
        self.onReady = onReady
        self.onError = onError
        self.onGiveUp = onGiveUp
        self.blurStill = spec.blurHash.flatMap { BlurHashDecoder.decode($0, width: 32, height: 32) }
    }

    deinit {
        // Backstop for a showing torn down without disappear: the lease is
        // idempotent and the pool drops a missing key, so this never throws —
        // and a handed-over borrow is never freed here (it belongs to the
        // viewer now).
        if !borrowHandedOver() {
            lease?.release()
        }
        if let owned = ownedPlayer {
            owned.pause()
            owned.replaceCurrentItem(with: nil)
        }
    }

    /// Supplies an externally owned player (mirrors Android's `player` param): the pool is
    /// skipped, but the reset protocol still applies.
    func useExternalPlayer(_ player: AVPlayer?) {
        externalPlayer = player
    }

    /// Opens the showing with the ambient `services`: borrows or builds the
    /// player, takes it over, arms observers. Non-view code hands its services
    /// here directly; views forward their environment.
    func appear(campaignKey: String?, services: MediaServices = .unconfigured) {
        self.campaignKey = campaignKey
        self.services = services
        isAppeared = true
        open()
    }

    /// Borrows or builds the player for the current `spec` and takes it over.
    /// A spec change while visible re-takes-over (the same player for a
    /// borrowed handover, a fresh player for an owned URL change — a released
    /// player is never reused).
    private func open() {
        let source = poolOverride ?? services.pool() ?? NoSdkVideoPool.shared()
        let keyed = key != nil && externalPlayer == nil
        usesLease = keyed
        let urlChanged = lastURL != nil && lastURL != spec.url
        lastURL = spec.url
        startMs = spec.playback.startMs
        if let externalPlayer {
            attach(externalPlayer, spec: spec)
            if playing { play() } else { pause() }
            return
        }
        if keyed {
            guard let key else {
                noteGaveUp()
                return
            }
            guard mediaUsableURL(spec.url) != nil else {
                degradeToStill(cause: "invalid_url")
                return
            }
            let fresh = source.obtainLease(
                key: key, url: spec.url, priority: poolPriority,
                onFailure: { [weak self] cause in self?.degradeToStill(cause: cause) }
            )
            if let current = lease, let fresh, fresh.player === current.player {
                // Re-open onto the player this showing already holds (a spec
                // set followed by appear, or a same-key remount): the fresh
                // share is dropped and the committed lease stays, so disappear
                // still frees exactly once. A share's release never frees.
                fresh.release()
            } else {
                if !borrowHandedOver() {
                    // The previous holder is gone (a re-point replaces it in
                    // the pool; eviction/teardown already dropped it): the
                    // identity check makes this a safe no-op either way.
                    lease?.release()
                }
                lease = fresh
            }
            guard let lease else {
                activePlayer = nil
                noteGaveUp()
                armSpinner(spec: spec)
                return
            }
            attach(lease.player, spec: spec, pool: source, poolKey: key)
            if playing { play() } else { pause() }
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
        if playing { play() } else { pause() }
    }

    /// Starts playback when this state drives it; inert without a live player.
    func play() {
        guard let player = activePlayer, !degraded, !failed else { return }
        player.play()
    }

    /// Pauses playback when this state drives it; inert without a live player.
    /// Pausing never re-takes-over, so it never re-seeks the playhead.
    func pause() {
        guard let player = activePlayer, !degraded, !failed else { return }
        player.pause()
    }

    /// Applies a mute toggle without re-taking-over (so it never re-seeks the playhead).
    func setMuted(_ muted: Bool) {
        activePlayer?.isMuted = muted
    }

    /// Re-applies the spec's mute level after a mute-only change (no re-seek).
    private func applyMuted() {
        setMuted(spec.playback.muted)
    }

    /// Seeks back to the start (replay, revisit): the position publishers
    /// follow on the next observer tick.
    func seekToStart() {
        ended = false
        attachedPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Releases the lease (a handed-over borrow belongs to the viewer now and
    /// is never freed here; a missing key — evicted or released — is a silent
    /// no-op) and releases the owned fallback. An external player is only
    /// detached, never touched.
    func disappear() {
        isAppeared = false
        spinnerTask?.cancel()
        spinnerTask = nil
        degraded = false
        gaveUpFired = false
        if !borrowHandedOver() {
            lease?.release()
        }
        lease = nil
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
        firstFrameShown = false
        ended = false
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
        trackItem(player.currentItem)
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
                // The playhead publishers, from the start: story drivers read
                // the state instead of the raw player (D16).
                let duration = self.attachedPlayer?.currentItem?.duration
                if let duration, duration.isNumeric, duration.seconds.isFinite,
                    duration.seconds > 0
                {
                    self.durationMs = Int64(duration.seconds * 1_000)
                }
                if time.isNumeric, time.seconds.isFinite, time.seconds >= 0 {
                    self.positionMs = Int64(max(time.seconds, 0) * 1_000)
                }
                if self.durationMs > 0, self.positionMs >= self.durationMs {
                    self.ended = true
                }
                if time.seconds.isFinite, time.seconds >= startSeconds {
                    self.noteFirstFrame()
                }
            }
        }
    }

    /// Attaches the status + failure observers to the item actually in the player,
    /// following `currentItem` swaps. The pool's looping entry swaps the take-over
    /// item for an `AVPlayerLooper` replica once its duration loads, and the
    /// template then never loads itself — an observer left on it watches an item
    /// that stays `.unknown` forever while its ready replica goes unreported. A
    /// player that advances is rescued by the time observer; one that never plays
    /// (a paused looping showing, the golden stub) stalls until its timeout.
    private func trackItem(_ item: AVPlayerItem?) {
        statusObserver?.invalidate()
        statusObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
        observedItem = item
        guard let item else { return }
        statusObserver = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor in self?.noteItemStatus(item) }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
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
        if let new, new !== observedItem {
            trackItem(new)
        }
    }

    private func noteFirstFrame() {
        guard !firstFrameShown, !failed else { return }
        guard attachedPlayer?.currentItem?.status == .readyToPlay else { return }
        firstFrameShown = true
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
        if !borrowHandedOver() {
            lease?.release()
        }
        lease = nil
        // A re-open onto an already-failed showing (spec set + appear) keeps
        // the still without re-reporting: one showing, one fault, like the
        // `noteItemFailed` guard above.
        let firstFault = !failed
        failed = true
        showSpinner = false
        spinnerTask?.cancel()
        activePlayer = nil
        if firstFault {
            services.reportHealth(campaignKey, .video, cause)
            onError?(cause)
        }
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
        guard showPlayer, nothingBetter, !firstFrameShown, !failed else { return }
        spinnerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(MediaImage.spinnerDelaySeconds * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.showPlayer, !self.firstFrameShown, !self.failed {
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
        observedItem = nil
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

/// The one video wrapper every surface renders through (D1, state-driven D16):
/// `MediaVideo(state:)` only attaches the layer, draws the D14 layers bottom
/// up — borrowed frame → campaign poster through `MediaImage` → BlurHash →
/// dark backdrop, a spinner only after `MediaImage.spinnerDelaySeconds` with
/// nothing better to show, every failure degrading to the still — fits the
/// video and calls no playback method. Play state, volume, seeks and repeat
/// all flow through `MediaVideoState`.
///
/// The state's owner configures it (`spec`, `playing`, callbacks) and mutates
/// it directly; the view only opens/closes it. With `keepAliveKey` the player
/// is borrowed under a lease (`obtainLease` on appear, `release` on
/// disappear): rebuilds (rotation, PIP drag) keep playing without restarting.
/// A refused borrow or an evicted holder renders the still — never an owned
/// player around the pool (D3). Without a key the state owns its player
/// outright (nudge, canvas). An externally supplied `player` is driven in
/// place (reset via the same take-over) and never paused, released or given
/// back.
///
/// Reads the campaign attribution (`digiaCampaignKey`) set by the hosting
/// surface, like `MediaImage` does: the wrapper knows nothing about campaigns
/// (R-C), it only passes the key to health reporting.
internal struct MediaVideo: View {
    @StateObject private var state: MediaVideoState

    @Environment(\.digiaCampaignKey) private var campaignKey
    @Environment(\.mediaServices) private var mediaServices
    /// Old-shape forwarding, set only by the adapter init below.
    private var adapterSpec: VideoSpec? = nil
    private var adapterPlaying: Bool? = nil

    /// State-driven (canonical): the owner configures `state` and mutates it
    /// directly; this view only opens/closes it and draws from it.
    init(state: MediaVideoState) {
        _state = StateObject(wrappedValue: state)
    }

    // TODO(r2-remove): temporary old-shape adapter so pre-R2 call sites still
    // compile. Forwards construction params into the state and live updates
    // through it; no logic of its own. The R2 migration lanes delete this when
    // the last caller builds its own state.
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
        let state = MediaVideoState(
            spec: spec,
            playing: playing,
            keepAliveKey: keepAliveKey,
            poolPriority: poolPriority,
            pool: pool,
            resourceLoader: resourceLoader,
            onReady: onReady,
            onError: onError,
            onGiveUp: onGiveUp
        )
        state.useExternalPlayer(player)
        _state = StateObject(wrappedValue: state)
        self.adapterSpec = spec
        self.adapterPlaying = playing
    }

    var body: some View {
        ZStack {
            Color.mediaBackdrop
            if let blurStill = state.blurStill {
                if let mode = state.spec.fit.contentMode {
                    Image(uiImage: blurStill)
                        .resizable()
                        .aspectRatio(contentMode: mode)
                } else {
                    Image(uiImage: blurStill)
                        .resizable()
                }
            }
            if !state.firstFrameShown, !state.failed,
               let posterURL = state.spec.posterURL, !posterURL.isEmpty
            {
                MediaImage(spec: ImageSpec(url: posterURL, fit: state.spec.fit))
            }
            if state.showPlayer, let active = state.activePlayer {
                MediaPlayerLayerView(player: active, gravity: state.spec.fit.videoGravity)
            }
            if state.showSpinner {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            state.appear(campaignKey: campaignKey, services: mediaServices)
        }
        .onDisappear {
            state.disappear()
        }
        .onChange(of: adapterSpec) { _ in
            if let spec = adapterSpec { state.spec = spec }
        }
        .onChange(of: adapterPlaying) { _ in
            if let playing = adapterPlaying { state.playing = playing }
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
