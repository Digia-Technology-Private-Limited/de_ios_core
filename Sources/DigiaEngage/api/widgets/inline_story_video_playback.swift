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

/// Owns local-file resolution and the complete AVPlayer lifecycle for both story surfaces.
/// Thumbnail and full-screen views provide policy through `StoryVideoPlaybackState`; observer,
/// seek, readiness, failure, and teardown behavior lives only here.
@MainActor
final class StoryVideoPlayback: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var poster: UIImage?
    @Published private(set) var showPlayerLayer = false

    private let urlString: String
    private let purpose: StoryVideoPlaybackPurpose
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
    private var loadTask: Task<Void, Never>?
    private var requestedPriority: StoryVideoCachePriority?
    private var loadGeneration: UInt = 0

    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var bufferingObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

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

    init(urlString: String, purpose: StoryVideoPlaybackPurpose) {
        self.urlString = urlString
        self.purpose = purpose
        applicationActive = UIApplication.shared.applicationState == .active
        if let frameMs = Self.posterFrameMs(for: purpose) {
            poster = StoryVideoPosterCache.image(
                for: StoryVideoPosterIdentity(url: urlString, frameMs: frameMs)
            )
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
    }

    func update(
        state nextState: StoryVideoPlaybackState,
        events: StoryVideoPlaybackEvents
    ) {
        let previous = state
        state = nextState
        self.events = events
        player?.isMuted = nextState.muted

        guard !terminalFailureReported else { return }
        if nextState.demand == .none {
            loadTask?.cancel()
            loadTask = nil
            requestedPriority = nil
            releasePlayer()
            prepareCachedPosterIfAvailable()
            return
        }

        let restartRequested = previous.restartGeneration != nextState.restartGeneration
        ensureAsset(
            priority: nextState.demand.priority ?? .eligible,
            needsPlayer: nextState.demand.needsPlayer
        )

        guard let player else { return }
        if !nextState.demand.needsPlayer {
            releasePlayer()
            return
        }
        if restartRequested, startPrepared {
            completionHandled = false
            player.pause()
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self, self.state.active, self.applicationActive else { return }
                self.player?.play()
            }
        } else if nextState.active, applicationActive {
            if startPrepared { player.play() }
        } else {
            player.pause()
        }
    }

    func playerLayerDidBecomeReady() {
        playerLayerReady = true
        revealPlayerIfReady(positionMs: currentPositionMs())
    }

    func tearDown() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        requestedPriority = nil
        cancelPosterGeneration()
        releasePlayer()
        localAsset = nil
    }

    private func prepareCachedPosterIfAvailable() {
        guard needsGeneratedPoster, poster == nil, loadTask == nil,
              let remoteURL = URL(string: urlString) else { return }
        let generation = loadGeneration &+ 1
        loadGeneration = generation
        loadTask = Task { @MainActor [weak self] in
            guard let cachedURL = await DigiaVideoFileCache.shared.cachedURL(for: remoteURL),
                  let self,
                  !Task.isCancelled,
                  self.loadGeneration == generation else {
                self?.loadTask = nil
                return
            }
            self.loadTask = nil
            let asset = AVURLAsset(url: cachedURL)
            self.localAsset = asset
            self.preparePoster(from: asset)
        }
    }

    private func ensureAsset(priority: StoryVideoCachePriority, needsPlayer: Bool) {
        if let localAsset {
            preparePoster(from: localAsset)
            if needsPlayer, player == nil { installPlayer(asset: localAsset) }
            return
        }
        if let requestedPriority, loadTask != nil, requestedPriority >= priority {
            return
        }
        guard let remoteURL = URL(string: urlString) else {
            handleTerminalFailure()
            return
        }

        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        requestedPriority = priority
        loadTask = Task { @MainActor [weak self] in
            do {
                let cachedURL = try await DigiaVideoFileCache.shared.localURL(
                    for: remoteURL,
                    priority: priority
                )
                guard let self,
                      !Task.isCancelled,
                      self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.requestedPriority = nil
                let asset = AVURLAsset(url: cachedURL)
                self.localAsset = asset
                self.preparePoster(from: asset)
                if self.state.demand.needsPlayer {
                    self.installPlayer(asset: asset)
                }
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.loadGeneration == generation else { return }
                self.loadTask = nil
                self.requestedPriority = nil
                self.handleTerminalFailure()
            }
        }
    }

    private func installPlayer(asset: AVURLAsset) {
        guard player == nil else { return }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = state.muted
        self.player = player

        statusObserver = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay: self.prepareStart()
                case .failed: self.handleTerminalFailure()
                default: break
                }
            }
        }
        durationObserver = item.observe(\.duration, options: [.initial, .new]) {
            [weak self] item, _ in
            Task { @MainActor in
                self?.revalidateStartAgainstKnownDuration(item.duration)
            }
        }
        bufferingObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.events.onBuffering(
                    player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                )
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.completeWindow() }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTerminalFailure() }
        }
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            Task { @MainActor in self?.handleTimeUpdate(time) }
        }
    }

    private func prepareStart() {
        guard !startPrepared, let player, let item = player.currentItem else { return }
        effectiveStartMs = configuredStartMs(for: item.duration)
        startPrepared = true
        seekToStart(retryAtZero: isThumbnail) { [weak self] in
            guard let self, self.state.active, self.applicationActive else { return }
            self.player?.play()
        }
    }

    private func revalidateStartAgainstKnownDuration(_ duration: CMTime) {
        guard isThumbnail, startPrepared else { return }
        let durationMs = milliseconds(duration)
        guard shouldFallbackToZeroThumbnailStart(
            effectiveStartMs: effectiveStartMs,
            naturalDurationMs: durationMs
        ) else { return }
        effectiveStartMs = 0
        player?.pause()
        seekToStart { [weak self] in
            guard let self, self.state.active, self.applicationActive else { return }
            self.player?.play()
        }
    }

    private func handleTimeUpdate(_ time: CMTime) {
        guard let player, state.active, applicationActive else { return }
        let positionMs = milliseconds(time)
        revealPlayerIfReady(positionMs: positionMs)
        let duration = player.currentItem?.duration.seconds ?? 0
        if duration.isFinite, duration > 0 {
            events.onProgress(min(max(time.seconds / duration, 0), 1))
        }
        if case let .thumbnail(item) = purpose,
           thumbnailPlaybackWindowEnded(
               item: item,
               currentPositionMs: positionMs,
               effectiveStartMs: effectiveStartMs
           ) {
            completeWindow()
        }
    }

    private func completeWindow() {
        guard applicationActive, !completionHandled, let player else { return }
        completionHandled = true
        player.pause()

        guard isThumbnail else {
            events.onEnded()
            return
        }
        if state.active, state.repeatWindow {
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self, self.state.active, self.applicationActive else { return }
                self.completionHandled = false
                self.player?.play()
            }
        } else {
            // Sequential handoff must not wait for a platform seek callback.
            events.onEnded()
            seekToStart(retryAtZero: true, hideCurrentFrame: false)
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
        guard let player else {
            seekInProgress = false
            completion?()
            return
        }
        let expectedPlayer = player
        let time = CMTime(value: effectiveStartMs, timescale: 1_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] succeeded in
            Task { @MainActor in
                self?.finishSeek(
                    generation: generation,
                    expectedPlayer: expectedPlayer,
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
        guard seekGeneration == generation, player === expectedPlayer else { return }
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

    private func handleTerminalFailure() {
        guard !terminalFailureReported else { return }
        terminalFailureReported = true
        player?.pause()
        showPlayerLayer = false
        cancelPosterGeneration()
        events.onFailed()
    }

    private func releasePlayer() {
        seekGeneration &+= 1
        statusObserver?.invalidate()
        durationObserver?.invalidate()
        bufferingObserver?.invalidate()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        statusObserver = nil
        durationObserver = nil
        bufferingObserver = nil
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        showPlayerLayer = false
        playerLayerReady = false
        startPrepared = false
        seekInProgress = false
        completionHandled = false
        readyReported = false
    }

    private func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        guard active else {
            player?.pause()
            return
        }
        guard state.active, state.demand.needsPlayer, startPrepared else { return }

        if isThumbnail {
            // Thumbnail sessions always restart from their configured beginning.
            completionHandled = false
            player?.pause()
            seekToStart(retryAtZero: true, hideCurrentFrame: false) { [weak self] in
                guard let self, self.state.active, self.applicationActive else { return }
                self.player?.play()
            }
        } else {
            // A full-screen story resumes where the app was interrupted.
            player?.play()
        }
    }

    private var isThumbnail: Bool {
        if case .thumbnail = purpose { return true }
        return false
    }

    private var needsGeneratedPoster: Bool {
        Self.posterFrameMs(for: purpose) != nil
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
        guard let player else { return 0 }
        return milliseconds(player.currentTime())
    }

    private func preparePoster(from asset: AVAsset) {
        guard let frameMs = Self.posterFrameMs(for: purpose),
              poster == nil,
              imageGenerator == nil else { return }
        let cacheKey = StoryVideoPosterIdentity(url: urlString, frameMs: frameMs)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let generationID = UUID()
        imageGenerator = generator
        imageGenerationID = generationID
        generatePoster(
            with: generator,
            atMilliseconds: frameMs,
            cacheKey: cacheKey,
            retryAtZero: true,
            generationID: generationID
        )
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
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 20 * 1_024 * 1_024
        return cache
    }()

    static func image(for key: StoryVideoPosterIdentity) -> UIImage? {
        cache.object(forKey: key.cacheKey as NSString)
    }

    static func store(_ image: UIImage, for key: StoryVideoPosterIdentity) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key.cacheKey as NSString, cost: cost)
    }
}
