import AVFoundation
import Combine
import UIKit

enum StoryVideoLoadDemand: Equatable {
    case none
    case poster(StoryVideoCachePriority)
    case playback(StoryVideoCachePriority)

    var priority: StoryVideoCachePriority? {
        switch self {
        case .none: nil
        case let .poster(priority), let .playback(priority): priority
        }
    }

    var needsPlayer: Bool {
        if case .playback = self { return true }
        return false
    }
}

struct StoryVideoPlaybackState: Equatable {
    let demand: StoryVideoLoadDemand
    let active: Bool
    let muted: Bool
    let repeatWindow: Bool
    let restartGeneration: Int
    var rewindOnEnd = true
    var repeatWhenInactive = false
}

struct StoryVideoPlaybackEvents {
    var onReady: @MainActor () -> Void = {}
    var onProgress: @MainActor (Double) -> Void = { _ in }
    var onEnded: @MainActor () -> Void = {}
    var onBuffering: @MainActor (Bool) -> Void = { _ in }
    var onFailed: @MainActor () -> Void = {}
}

enum StoryVideoPlaybackPurpose {
    case thumbnail(StoryItemConfig)
    case fullScreen(StoryItemConfig)
}

struct StoryVideoPosterIdentity: Hashable {
    let url: String
    let frameMs: Int64

    var cacheKey: String {
        String(reflecting: self)
    }
}

/// Owns the complete video lifecycle for the canvas story surfaces (R2-STORY): the player is
/// borrowed through an owned `MediaVideoState` — keyless, so the state owns its player
/// outright via the factory — instead of a directly built `AVPlayer`. The item still reads
/// through the D2 range-cache asset (one download serves playback and caching, D2), and the
/// first-frame reveal, poster generation, seek, readiness, failure, and teardown behavior
/// below is unchanged: only the player source moved, from `AVPlayer(playerItem:)` to the
/// state. Thumbnail and full-screen views provide policy through `StoryVideoPlaybackState`.
///
/// `player` mirrors the state's borrowed instance for the layer hosts; `poster` and
/// `showPlayerLayer` behave exactly as before.
@MainActor
final class StoryVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var poster: UIImage?
    @Published private(set) var showPlayerLayer = false
    /// The campaign that a `media_load_failed` report names.
    var campaignKey: String?

    private let urlString: String
    private let purpose: StoryVideoPlaybackPurpose
    private let posterIdentity: StoryVideoPosterIdentity?
    /// The D2 range-cache loader the poster asset and the state's player item read through
    /// (one download serves playback and caching, D2). Tests inject a loader backed by a
    /// fake store; production uses the process-wide shared loader.
    private let resourceLoader: MediaResourceLoader
    /// The state's borrow: keyless (each card owns its player, as before — the pool is for
    /// rail/viewer showings under keep-alive keys), driven by `playing`/spec below. Health
    /// stays reported directly through `reportMediaLoadFailed` (the state runs with default
    /// services, so it reports nothing itself — one report per fault, as before).
    private let videoState: MediaVideoState
    private var videoAppeared = false
    private var applicationActive: Bool
    private var lifecycleSubscriptions = Set<AnyCancellable>()
    private var state = StoryVideoPlaybackState(
        demand: .none,
        active: false,
        muted: true,
        repeatWindow: false,
        restartGeneration: 0
    )
    private var events = StoryVideoPlaybackEvents()
    private var localAsset: AVURLAsset?

    private var driverTask: Task<Void, Never>?
    private var lastWaiting: Bool?

    private var effectiveStartMs: Int64 = 0
    private var startPrepared = false
    private var completionHandled = false
    private var terminalFailureReported = false
    private var playerLayerReady = false
    private var seekInProgress = false
    private var seekGeneration: UInt = 0
    private var readyReported = false

    private var imageGenerator: AVAssetImageGenerator?
    private var imageGenerationID: UUID?

    init(
        urlString: String,
        purpose: StoryVideoPlaybackPurpose,
        resourceLoader: MediaResourceLoader? = nil
    ) {
        self.urlString = urlString
        self.purpose = purpose
        let loader = resourceLoader ?? SharedMediaResourceLoader.shared
        self.resourceLoader = loader
        let videoState = MediaVideoState(
            spec: Self.stateSpec(urlString: urlString, purpose: purpose, muted: true),
            playing: false,
            resourceLoader: loader
        )
        self.videoState = videoState
        posterIdentity = Self.posterFrameMs(for: purpose).map {
            StoryVideoPosterIdentity(url: urlString, frameMs: $0)
        }
        applicationActive = UIApplication.shared.applicationState == .active
        if let posterIdentity {
            poster = StoryVideoPosterCache.image(for: posterIdentity)
            StoryVideoPosterCache.publisher(for: posterIdentity)
                .sink { [weak self] image in
                    Task { @MainActor in self?.poster = image }
                }
                .store(in: &lifecycleSubscriptions)
        }
        // The state's borrow, mirrored for the layer hosts (the state's own take-over,
        // observers and health stay inside the state — this class only mirrors and drives
        // the window policy below).
        videoState.$activePlayer
            .sink { [weak self] in self?.player = $0 }
            .store(in: &lifecycleSubscriptions)
        // The ready signal the old item-status observer provided: the state's first frame.
        videoState.$firstFrameShown
            .sink { [weak self] shown in
                guard shown else { return }
                self?.prepareStart()
            }
            .store(in: &lifecycleSubscriptions)
        // The duration revalidation the old duration observer provided.
        videoState.$durationMs
            .sink { [weak self] _ in self?.revalidateStartAgainstKnownDuration() }
            .store(in: &lifecycleSubscriptions)
        videoState.onError = { [weak self] cause in
            self?.handleTerminalFailure(cause: cause)
        }
        videoState.onGiveUp = { [weak self] in
            guard let self, !self.terminalFailureReported else { return }
            self.handleTerminalFailure()
        }

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.setApplicationActive(false) }
            }
            .store(in: &lifecycleSubscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.setApplicationActive(true) }
            }
            .store(in: &lifecycleSubscriptions)
        preparePosterIfAvailable()
    }

    /// The state's spec for this purpose: the window start up front (the take-over seeks
    /// there at attach, exactly where the old `prepareStart` sought), never autoplay (the
    /// old engine only played once ready and active — `playing` below drives), never loop
    /// (window repeat stays in `completeWindow`, as before).
    private static func stateSpec(
        urlString: String, purpose: StoryVideoPlaybackPurpose, muted: Bool
    ) -> VideoSpec {
        switch purpose {
        case let .thumbnail(item):
            let startMs = max(item.thumbnailPlayback.startTimeMs, 0)
            return VideoSpec(
                url: urlString,
                fit: item.thumbnailBoxFit.toMediaFit,
                playback: Playback(
                    loop: false, autoplay: false, muted: muted, startMs: Int(startMs))
            )
        case let .fullScreen(item):
            return VideoSpec(
                url: urlString,
                fit: item.boxFit.toMediaFit,
                playback: Playback(loop: false, autoplay: false, muted: muted, startMs: 0)
            )
        }
    }

    func update(
        state nextState: StoryVideoPlaybackState,
        events: StoryVideoPlaybackEvents
    ) {
        let previous = state
        state = nextState
        self.events = events

        guard !terminalFailureReported else { return }
        if nextState.demand == .none {
            disappearVideo()
            if applicationActive {
                preparePosterIfAvailable()
            } else {
                cancelPosterWork()
            }
            return
        }
        // An unusable URL reports `invalid_url` with no fetch, as before — before any poster
        // or player work starts.
        guard mediaUsableURL(urlString) != nil else {
            handleTerminalFailure(cause: "invalid_url")
            return
        }
        ensurePosterAsset()

        guard nextState.demand.needsPlayer else {
            disappearVideo()
            return
        }
        appearVideo()

        let restartRequested = previous.restartGeneration != nextState.restartGeneration
        if restartRequested, startPrepared {
            completionHandled = false
            videoState.pause()
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self, self.state.active, self.applicationActive else { return }
                self.videoState.play()
            }
        } else if nextState.active, applicationActive {
            if startPrepared { videoState.play() }
        } else {
            videoState.pause()
        }
    }

    func playerLayerDidBecomeReady() {
        playerLayerReady = true
        revealPlayerIfReady(positionMs: currentPositionMs())
    }

    func tearDown() {
        cancelPosterWork()
        disappearVideo()
        localAsset = nil
    }

    /// Borrows (or reuses) the state's player for the current spec and applies the window
    /// policy: a mute-only change applies without re-seeking (the state's `applyMuted`
    /// arm), play/pause follows `active` without unmounting.
    private func appearVideo() {
        videoState.spec = Self.stateSpec(
            urlString: urlString, purpose: purpose, muted: state.muted)
        if !videoAppeared {
            videoAppeared = true
            videoState.appear(campaignKey: campaignKey)
        }
        videoState.playing = state.active && applicationActive
        // Synchronous, like the old install: the hosts read `player` in the same pass.
        player = videoState.activePlayer
        startDriver()
    }

    /// Releases the borrow and stops the window driver. The poster's cached frame and the
    /// on-disk bytes stay — only the holder goes.
    private func disappearVideo() {
        stopDriver()
        seekGeneration &+= 1
        videoAppeared = false
        videoState.disappear()
        // Synchronous, like the old release: the hosts drop the layer in the same pass.
        player = videoState.activePlayer
        startPrepared = false
        seekInProgress = false
        completionHandled = false
        readyReported = false
        playerLayerReady = false
        showPlayerLayer = false
    }

    /// The window driver (was the item time + status + end observers): progress and the end
    /// from the state's playhead publishers, the stall signal from the borrowed instance
    /// (no state equivalent), all at the old 50 ms cadence. Runs once per appear — an update
    /// while appeared keeps the running task (no buffering refire, as with the old observers).
    private func startDriver() {
        guard driverTask == nil else { return }
        driverTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                handleDriverTick()
            }
        }
    }

    private func stopDriver() {
        driverTask?.cancel()
        driverTask = nil
        lastWaiting = nil
    }

    private func handleDriverTick() {
        guard applicationActive, let active = videoState.activePlayer else { return }
        // The stall signal, like the old buffering observer: ungated, fires on change.
        let waiting = active.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if waiting != lastWaiting {
            lastWaiting = waiting
            events.onBuffering(waiting)
        }
        let positionMs = videoState.positionMs
        let durationMs = videoState.durationMs
        if state.active {
            revealPlayerIfReady(positionMs: positionMs)
            if durationMs > 0 {
                events.onProgress(min(max(
                    Double(positionMs) / Double(durationMs), 0), 1))
            }
            if case let .thumbnail(item) = purpose,
               thumbnailPlaybackWindowEnded(
                   item: item,
                   currentPositionMs: positionMs,
                   effectiveStartMs: effectiveStartMs
               ) {
                completeWindow()
                return
            }
        }
        // The end, like the old end notification: fires whenever the playhead reaches the
        // end, even if policy has since paused the showing — `completeWindow` decides.
        if durationMs > 0, positionMs >= durationMs, !waiting {
            completeWindow()
        }
    }

    /// Resolves the poster asset for `urlString`: range-cache-backed for remote URLs (the
    /// player reads through the store and every fetched range is saved as it plays — one
    /// download serves playback and caching, so the old stream-plus-separate-download is
    /// gone), direct for `file://` and for URLs the private scheme cannot represent.
    /// Poster generation only — the player item comes from the state's take-over now.
    private func ensurePosterAsset() {
        guard let remoteURL = mediaUsableURL(urlString) else { return }
        if localAsset == nil {
            if remoteURL.isFileURL {
                localAsset = AVURLAsset(url: remoteURL)
            } else if let item = resourceLoader.playerItem(for: remoteURL),
                      let asset = item.asset as? AVURLAsset
            {
                // `playerItem(for:)` wires the loader on its own delegate queue and wraps the
                // item's asset; reusing that asset keeps this file off the loader's threading
                // contract.
                localAsset = asset
            } else {
                localAsset = AVURLAsset(url: remoteURL)
            }
        }
        guard let localAsset else { return }
        preparePoster(from: localAsset)
    }

    private func prepareStart() {
        guard !startPrepared, let item = videoState.activePlayer?.currentItem else { return }
        effectiveStartMs = configuredStartMs(for: item.duration)
        startPrepared = true
        seekToStart(retryAtZero: isThumbnail) { [weak self] in
            guard let self, self.state.active, self.applicationActive else { return }
            self.videoState.play()
        }
    }

    private func revalidateStartAgainstKnownDuration() {
        guard isThumbnail, startPrepared else { return }
        let durationMs = milliseconds(videoState.activePlayer?.currentItem?.duration ?? .indefinite)
        guard shouldFallbackToZeroThumbnailStart(
            effectiveStartMs: effectiveStartMs,
            naturalDurationMs: durationMs
        ) else { return }
        effectiveStartMs = 0
        videoState.pause()
        seekToStart { [weak self] in
            guard let self, self.state.active, self.applicationActive else { return }
            self.videoState.play()
        }
    }

    private func completeWindow() {
        guard applicationActive, !completionHandled else { return }
        completionHandled = true
        videoState.pause()

        guard isThumbnail else {
            events.onEnded()
            return
        }
        if (state.active || state.repeatWhenInactive), state.repeatWindow {
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self,
                      self.state.active || self.state.repeatWhenInactive,
                      self.applicationActive else { return }
                self.completionHandled = false
                self.videoState.play()
            }
        } else {
            // Sequential handoff must not wait for a platform seek callback.
            events.onEnded()
            if state.rewindOnEnd {
                seekToStart(retryAtZero: true, hideCurrentFrame: false)
            }
        }
    }

    private func seekToStart(
        retryAtZero: Bool = false,
        hideCurrentFrame: Bool = true,
        completion: (@MainActor () -> Void)? = nil
    ) {
        if hideCurrentFrame { showPlayerLayer = false }
        seekInProgress = true
        seekGeneration &+= 1
        let generation = seekGeneration
        guard let active = videoState.activePlayer else {
            seekInProgress = false
            completion?()
            return
        }
        let time = CMTime(value: effectiveStartMs, timescale: 1_000)
        active.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] succeeded in
            Task { @MainActor in
                self?.finishSeek(
                    generation: generation,
                    expectedPlayer: active,
                    succeeded: succeeded,
                    retryAtZero: retryAtZero,
                    hideCurrentFrame: hideCurrentFrame,
                    completion: completion
                )
            }
        }
    }

    private func finishSeek(
        generation: UInt,
        expectedPlayer: AVPlayer,
        succeeded: Bool,
        retryAtZero: Bool,
        hideCurrentFrame: Bool,
        completion: (@MainActor () -> Void)?
    ) {
        guard seekGeneration == generation, videoState.activePlayer === expectedPlayer else { return }
        seekGeneration &+= 1
        switch thumbnailSeekRecoveryAction(
            succeeded: succeeded,
            retryAtZero: retryAtZero,
            effectiveStartMs: effectiveStartMs
        ) {
        case .complete:
            seekInProgress = false
            revealPlayerIfReady(positionMs: currentPositionMs())
            completion?()
        case .retryAtZero:
            effectiveStartMs = 0
            seekToStart(hideCurrentFrame: hideCurrentFrame, completion: completion)
        case .fail:
            seekInProgress = false
            handleTerminalFailure()
        }
    }

    private func revealPlayerIfReady(positionMs: Int64) {
        guard state.active,
              applicationActive,
              startPrepared,
              playerLayerReady,
              !seekInProgress,
              positionMs >= effectiveStartMs else { return }
        showPlayerLayer = true
        if !readyReported {
            readyReported = true
            events.onReady()
        }
    }

    private func handleTerminalFailure(cause: String? = nil) {
        guard !terminalFailureReported else { return }
        terminalFailureReported = true
        // Every failure carries a non-nil cause (D5, iOS-wide rule): item failures are mapped
        // by the state through `mediaVideoFailureCause`, anything else is delivery, not an
        // author fault, and reports as network.
        let cause = cause ?? "network"
        reportMediaLoadFailed(.video, cause: cause, campaignKey: campaignKey)
        videoState.pause()
        showPlayerLayer = false
        cancelPosterWork()
        events.onFailed()
    }

    private func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        guard active else {
            videoState.pause()
            cancelPosterWork()
            return
        }
        preparePosterIfAvailable()
        guard state.active, state.demand.needsPlayer, startPrepared else { return }

        if isThumbnail {
            // Thumbnail sessions always restart from their configured beginning.
            completionHandled = false
            videoState.pause()
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self, self.state.active, self.applicationActive else { return }
                self.videoState.play()
            }
        } else {
            // A full-screen story resumes where the app was interrupted.
            videoState.play()
        }
    }

    private var isThumbnail: Bool {
        if case .thumbnail = purpose { return true }
        return false
    }

    private func configuredStartMs(for duration: CMTime) -> Int64 {
        guard case let .thumbnail(item) = purpose else { return 0 }
        return effectiveThumbnailStartMs(
            item: item,
            naturalDurationMs: milliseconds(duration)
        )
    }

    private func milliseconds(_ time: CMTime) -> Int64 {
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? Int64(seconds * 1_000) : 0
    }

    private func currentPositionMs() -> Int64 {
        videoState.positionMs
    }

    private func preparePoster(from asset: AVAsset) {
        guard let posterIdentity,
              poster == nil,
              imageGenerator == nil else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let generationID = UUID()
        imageGenerator = generator
        imageGenerationID = generationID
        generatePoster(
            with: generator,
            atMilliseconds: posterIdentity.frameMs,
            cacheKey: posterIdentity,
            retryAtZero: true,
            generationID: generationID
        )
    }

    /// The poster path, repointed at the D2 asset (Q1): the frame is generated from the same
    /// range-cached asset the player reads, so only the requested first range is fetched —
    /// no whole-file download just to show a still.
    private func preparePosterIfAvailable() {
        guard applicationActive,
              poster == nil,
              posterIdentity != nil else { return }
        if let localAsset {
            preparePoster(from: localAsset)
        }
    }

    private func generatePoster(
        with generator: AVAssetImageGenerator,
        atMilliseconds milliseconds: Int64,
        cacheKey: StoryVideoPosterIdentity,
        retryAtZero: Bool,
        generationID: UUID
    ) {
        let time = CMTime(value: milliseconds, timescale: 1_000)
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
            [weak self] _, image, _, result, _ in
            Task { @MainActor in
                guard let self, self.imageGenerationID == generationID else { return }
                if result == .succeeded, let image {
                    let poster = UIImage(cgImage: image)
                    StoryVideoPosterCache.store(poster, for: cacheKey)
                    self.poster = poster
                    self.cancelPosterGeneration()
                } else if retryAtZero, milliseconds != 0 {
                    guard let generator = self.imageGenerator else { return }
                    self.generatePoster(
                        with: generator,
                        atMilliseconds: 0,
                        cacheKey: cacheKey,
                        retryAtZero: false,
                        generationID: generationID
                    )
                } else {
                    self.cancelPosterGeneration()
                }
            }
        }
    }

    private func cancelPosterGeneration() {
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        imageGenerationID = nil
    }

    private func cancelPosterWork() {
        cancelPosterGeneration()
    }

    private static func posterFrameMs(for purpose: StoryVideoPlaybackPurpose) -> Int64? {
        switch purpose {
        case let .thumbnail(item):
            item.thumbnail == nil ? max(item.thumbnailPlayback.startTimeMs, 0) : nil
        case let .fullScreen(item):
            item.thumbnail == nil ? 0 : nil
        }
    }
}

@MainActor
enum StoryVideoPosterCache {
    private static let stored = PassthroughSubject<StoryVideoPosterIdentity, Never>()
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 20 * 1_024 * 1_024
        return cache
    }()

    static func image(for key: StoryVideoPosterIdentity) -> UIImage? {
        cache.object(forKey: key.cacheKey as NSString)
    }

    static func publisher(
        for key: StoryVideoPosterIdentity
    ) -> AnyPublisher<UIImage, Never> {
        stored.compactMap { storedKey in
            storedKey == key ? image(for: key) : nil
        }
        .eraseToAnyPublisher()
    }

    static func store(_ image: UIImage, for key: StoryVideoPosterIdentity) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key.cacheKey as NSString, cost: cost)
        stored.send(key)
    }
}
