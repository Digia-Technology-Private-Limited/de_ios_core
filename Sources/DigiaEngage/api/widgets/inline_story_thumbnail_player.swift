import AVFoundation
import Combine
import SwiftUI
import UIKit

struct StoryRailGeometry: Equatable {
    var rail: CGRect?
    var cards: [Int: CGRect] = [:]
}

struct StoryRailGeometryPreference: PreferenceKey {
    static let defaultValue = StoryRailGeometry()

    static func reduce(value: inout StoryRailGeometry, nextValue: () -> StoryRailGeometry) {
        let next = nextValue()
        if let rail = next.rail {
            value.rail = rail
        }
        value.cards.merge(next.cards) { _, new in new }
    }
}

struct ThumbnailPlaybackViewState: Equatable {
    let eligible: Bool
    let scheduled: Bool
    let shouldPlay: Bool
    let canLoad: Bool
    let mode: ThumbnailVideoPlaybackMode
    let playableIndices: Set<Int>
    let restartGeneration: Int
}

struct StoryThumbnailPlayerIdentity: Hashable {
    let itemType: StoryMediaType
    let url: String
    let playback: StoryThumbnailPlaybackIdentity
    let thumbnail: StoryThumbnailIdentity?

    var cacheKey: String {
        String(reflecting: self)
    }
}

struct StoryThumbnailPlaybackIdentity: Hashable {
    let startTimeMs: Int64
    let durationMode: StoryThumbnailDurationMode
    let durationMs: Int64?
}

enum StoryThumbnailIdentity: Hashable {
    case image(source: String, fit: StoryMediaFit, blurHash: String?)
    case color(String)
}

func thumbnailPlayerIdentity(_ item: StoryItemConfig) -> StoryThumbnailPlayerIdentity {
    StoryThumbnailPlayerIdentity(
        itemType: item.type,
        url: item.url,
        playback: StoryThumbnailPlaybackIdentity(
            startTimeMs: item.thumbnailPlayback.startTimeMs,
            durationMode: item.thumbnailPlayback.durationMode,
            durationMs:
                item.thumbnailPlayback.durationMode == .fixed
                    ? item.thumbnailPlayback.durationMs
                    : nil
        ),
        thumbnail: item.thumbnail.map { thumbnail in
            switch thumbnail {
            case let .image(source, fit, placeholder):
                .image(source: source, fit: fit, blurHash: placeholder?.blurHash)
            case let .color(value):
                .color(value)
            }
        }
    )
}

struct ThumbnailRevealState: Equatable {
    let shouldPlay: Bool
    let startPrepared: Bool
    let playerLayerReady: Bool
    let seekInProgress: Bool
    let effectiveStartMs: Int64

    func canReveal(at positionMs: Int64) -> Bool {
        shouldPlay
            && startPrepared
            && playerLayerReady
            && !seekInProgress
            && positionMs >= effectiveStartMs
    }
}

func shouldComposeThumbnailPlayer(
    hasExplicitThumbnail: Bool,
    scheduled: Bool
) -> Bool {
    !hasExplicitThumbnail || scheduled
}

struct StoryThumbnailPlaceholderView: View {
    let thumbnail: StoryThumbnailConfig?
    var fitOverride: StoryMediaFit? = nil

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.10)
            switch thumbnail {
            case let .color(value):
                Color(hex: value) ?? Color(red: 0.10, green: 0.10, blue: 0.10)
            case let .image(source, fit, placeholder):
                if let url = URL(string: source) {
                    fitted(
                        DigiaCachedImageView(
                            url: url,
                            placeholder: AnyView(
                                BlurHashPlaceholderView(placeholder: placeholder)
                            )
                        ),
                        fit: fitOverride ?? fit
                    )
                }
            case nil:
                EmptyView()
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func fitted<Content: View>(
        _ content: Content,
        fit: StoryMediaFit
    ) -> some View {
        switch fit {
        case .cover:
            content.aspectRatio(contentMode: .fill)
        case .contain:
            content.aspectRatio(contentMode: .fit)
        case .fill:
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

@MainActor
struct StoryThumbnailVideoView: View {
    let item: StoryItemConfig
    let state: ThumbnailPlaybackViewState
    let onWindowCompleted: () -> Void
    let onFailed: () -> Void

    @StateObject private var model: StoryThumbnailPlayerModel

    init(
        item: StoryItemConfig,
        state: ThumbnailPlaybackViewState,
        onWindowCompleted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        self.item = item
        self.state = state
        self.onWindowCompleted = onWindowCompleted
        self.onFailed = onFailed
        _model = StateObject(wrappedValue: StoryThumbnailPlayerModel(item: item))
    }

    var body: some View {
        ZStack {
            Color.black
            StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            if item.thumbnail == nil, let poster = model.poster {
                fittedPoster(poster)
            }
            if let player = model.player {
                InlineStoryPlayerLayer(
                    player: player,
                    gravity: item.thumbnailBoxFit.videoGravity,
                    onReadyForDisplay: model.playerLayerDidBecomeReady
                )
                .opacity(model.showPlayerLayer ? 1 : 0)
            }
        }
        .onAppear {
            model.update(
                state: state,
                onWindowCompleted: onWindowCompleted,
                onFailed: onFailed
            )
        }
        .onChange(of: state) { next in
            model.update(
                state: next,
                onWindowCompleted: onWindowCompleted,
                onFailed: onFailed
            )
        }
        .onDisappear {
            model.tearDown()
        }
    }

    @ViewBuilder
    private func fittedPoster(_ poster: UIImage) -> some View {
        let image = Image(uiImage: poster).resizable()
        if item.thumbnailBoxFit.stretchesImage {
            image.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            image.aspectRatio(contentMode: item.thumbnailBoxFit.imageContentMode)
        }
    }
}

@MainActor
private final class StoryThumbnailPlayerModel: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var poster: UIImage?
    @Published private(set) var showPlayerLayer = false

    private let item: StoryItemConfig
    private var bundle: DigiaVideoPlaybackBundle?
    private var state = ThumbnailPlaybackViewState(
        eligible: false,
        scheduled: false,
        shouldPlay: false,
        canLoad: false,
        mode: .simultaneous,
        playableIndices: [],
        restartGeneration: 0
    )
    private var effectiveStartMs: Int64 = 0
    private var startPrepared = false
    private var completionHandled = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var durationObserver: NSKeyValueObservation?
    private var terminalFailureReported = false
    private var seekGeneration: UInt = 0
    private var seekInProgress = false
    private var imageGenerator: AVAssetImageGenerator?
    private var imageGenerationID: UUID?
    private var onWindowCompleted: () -> Void = {}
    private var onFailed: () -> Void = {}
    private var playerLayerReady = false
    private var playerPreparationTask: Task<Void, Never>?
    private var posterPreparationTask: Task<Void, Never>?

    init(item: StoryItemConfig) {
        self.item = item
        poster = StoryThumbnailPosterCache.image(for: thumbnailPlayerIdentity(item))
    }

    func update(
        state: ThumbnailPlaybackViewState,
        onWindowCompleted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        let wasPlaying = self.state.shouldPlay
        let restartRequested = self.state.restartGeneration != state.restartGeneration
        self.state = state
        self.onWindowCompleted = onWindowCompleted
        self.onFailed = onFailed
        if !state.canLoad {
            if bundle != nil {
                tearDown()
            }
            return
        }
        if item.thumbnail != nil, !state.scheduled {
            if bundle != nil {
                tearDown()
            }
            return
        }
        if bundle == nil, !state.shouldPlay {
            prepareCachedPosterIfNeeded()
            return
        }
        prepareIfNeeded()

        if terminalFailureReported { return }
        guard let player else { return }
        if restartRequested {
            completionHandled = false
            player.pause()
            guard startPrepared else { return }
            seekToStart(retryAtZero: true, hideCurrentFrame: false) {
                guard self.state.shouldPlay else { return }
                player.play()
            }
            return
        }
        if state.shouldPlay {
            if !wasPlaying, startPrepared {
                completionHandled = false
                player.play()
            }
        } else {
            player.pause()
            if !state.eligible {
                resetToStart()
            }
        }
    }

    private func prepareIfNeeded() {
        guard bundle == nil else { return }
        guard let url = URL(string: item.url) else {
            handleTerminalFailure()
            return
        }
        guard playerPreparationTask == nil else { return }
        playerPreparationTask = Task { @MainActor [weak self] in
            do {
                let next = try await DigiaVideoPlaybackBundle.make(url: url, looping: false)
                guard let self, !Task.isCancelled else {
                    next.releasePlaybackResources()
                    return
                }
                self.playerPreparationTask = nil
                guard self.state.canLoad,
                      self.item.thumbnail == nil || self.state.scheduled else {
                    next.releasePlaybackResources()
                    return
                }
                self.install(next)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.playerPreparationTask = nil
                self.handleTerminalFailure()
            }
        }
    }

    private func install(_ next: DigiaVideoPlaybackBundle) {
        next.player.isMuted = true
        bundle = next
        player = next.player
        preparePoster(from: next.player.currentItem?.asset)

        if let currentItem = next.player.currentItem {
            statusObserver = currentItem.observe(
                \.status,
                options: [.initial, .new]
            ) { [weak self] observed, _ in
                Task { @MainActor in
                    guard let self else { return }
                    switch observed.status {
                    case .readyToPlay:
                        self.prepareStart()
                    case .failed:
                        self.handleTerminalFailure()
                    default:
                        break
                    }
                }
            }
            durationObserver = currentItem.observe(
                \.duration,
                options: [.initial, .new]
            ) { [weak self] observed, _ in
                Task { @MainActor in
                    self?.revalidateStartAgainstKnownDuration(observed.duration)
                }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.completeWindow() }
            }
            failObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleTerminalFailure() }
            }
        }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = next.player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.state.shouldPlay else { return }
                let positionMs = Int64(max(time.seconds, 0) * 1000)
                self.revealPlayerLayerIfReady(positionMs: positionMs)
                if thumbnailPlaybackWindowEnded(
                    item: self.item,
                    currentPositionMs: positionMs,
                    effectiveStartMs: self.effectiveStartMs
                ) {
                    self.completeWindow()
                }
            }
        }
    }

    private func prepareCachedPosterIfNeeded() {
        guard item.thumbnail == nil,
              poster == nil,
              imageGenerator == nil,
              posterPreparationTask == nil,
              let remoteURL = URL(string: item.url) else {
            return
        }
        posterPreparationTask = Task { @MainActor [weak self] in
            do {
                let localURL = try await DigiaVideoFileCache.shared.localURL(for: remoteURL)
                guard let self, !Task.isCancelled else { return }
                self.posterPreparationTask = nil
                self.preparePoster(from: DigiaVideoStreaming.makeAsset(for: localURL))
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.posterPreparationTask = nil
            }
        }
    }

    private func prepareStart() {
        guard !startPrepared, let player, let currentItem = player.currentItem else { return }
        let seconds = currentItem.duration.seconds
        let naturalDurationMs =
            seconds.isFinite && seconds > 0 ? Int64(seconds * 1000) : 0
        effectiveStartMs = effectiveThumbnailStartMs(
            item: item,
            naturalDurationMs: naturalDurationMs
        )
        startPrepared = true
        seekToStart(retryAtZero: true) {
            if self.state.shouldPlay {
                player.play()
            }
        }
    }

    private func revalidateStartAgainstKnownDuration(_ duration: CMTime) {
        let seconds = duration.seconds
        let naturalDurationMs =
            seconds.isFinite && seconds > 0 ? Int64(seconds * 1_000) : 0
        guard startPrepared,
              shouldFallbackToZeroThumbnailStart(
                  effectiveStartMs: effectiveStartMs,
                  naturalDurationMs: naturalDurationMs
              )
        else {
            return
        }

        effectiveStartMs = 0
        player?.pause()
        seekToStart {
            guard self.state.shouldPlay else { return }
            self.player?.play()
        }
    }

    private func preparePoster(from asset: AVAsset?) {
        let cacheKey = thumbnailPlayerIdentity(item)
        guard item.thumbnail == nil,
              poster == nil,
              imageGenerator == nil,
              let asset
        else {
            return
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 512, height: 512)
        let generationID = UUID()
        imageGenerator = generator
        imageGenerationID = generationID
        generatePoster(
            with: generator,
            atMilliseconds: max(item.thumbnailPlayback.startTimeMs, 0),
            cacheKey: cacheKey,
            retryAtZero: true,
            generationID: generationID
        )
    }

    private func generatePoster(
        with generator: AVAssetImageGenerator,
        atMilliseconds milliseconds: Int64,
        cacheKey: StoryThumbnailPlayerIdentity,
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
                    StoryThumbnailPosterCache.store(poster, for: cacheKey)
                    self.poster = poster
                    self.imageGenerator = nil
                    self.imageGenerationID = nil
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
                    self.imageGenerator = nil
                    self.imageGenerationID = nil
                }
            }
        }
    }

    private func completeWindow() {
        guard !completionHandled, let player else { return }
        completionHandled = true
        player.pause()

        if state.shouldPlay,
           shouldRepeatThumbnailPlaybackWindow(
               mode: state.mode,
               eligibleVideoCount: state.playableIndices.count
           )
        {
            seekToStart(retryAtZero: true, hideCurrentFrame: false) {
                guard self.state.shouldPlay else { return }
                self.completionHandled = false
                player.play()
            }
        } else {
            // The outgoing player's reset is best-effort background cleanup.
            // Coordinator advancement must not depend on AVPlayer invoking a
            // remote seek callback; some assets move currentTime successfully
            // without ever calling that completion handler.
            onWindowCompleted()
            seekToStart(retryAtZero: true, hideCurrentFrame: false)
        }
    }

    private func resetToStart() {
        seekToStart(retryAtZero: true)
    }

    private func seekToStart(
        retryAtZero: Bool = false,
        hideCurrentFrame: Bool = true,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        if hideCurrentFrame {
            showPlayerLayer = false
        }
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
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] succeeded in
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
        completion: (@MainActor @Sendable () -> Void)?
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
            completion?()
        case .retryAtZero:
            effectiveStartMs = 0
            seekToStart(
                hideCurrentFrame: hideCurrentFrame,
                completion: completion
            )
        case .fail:
            seekInProgress = false
            handleTerminalFailure()
        }
    }

    private func handleTerminalFailure() {
        guard !terminalFailureReported else { return }
        terminalFailureReported = true
        player?.pause()
        showPlayerLayer = false
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        imageGenerationID = nil
        onFailed()
    }

    func playerLayerDidBecomeReady() {
        playerLayerReady = true
        revealPlayerLayerIfReady(positionMs: currentPositionMs())
    }

    private func revealPlayerLayerIfReady(positionMs: Int64) {
        let revealState = ThumbnailRevealState(
            shouldPlay: state.shouldPlay,
            startPrepared: startPrepared,
            playerLayerReady: playerLayerReady,
            seekInProgress: seekInProgress,
            effectiveStartMs: effectiveStartMs
        )
        guard revealState.canReveal(at: positionMs) else {
            return
        }
        showPlayerLayer = true
    }

    private func currentPositionMs() -> Int64 {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite && seconds > 0 ? Int64(seconds * 1_000) : 0
    }

    func tearDown() {
        seekGeneration &+= 1
        playerPreparationTask?.cancel()
        posterPreparationTask?.cancel()
        playerPreparationTask = nil
        posterPreparationTask = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        imageGenerationID = nil
        statusObserver?.invalidate()
        durationObserver?.invalidate()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let failObserver {
            NotificationCenter.default.removeObserver(failObserver)
        }
        statusObserver = nil
        durationObserver = nil
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        player?.pause()
        if let bundle {
            bundle.releasePlaybackResources()
        }
        player = nil
        bundle = nil
        startPrepared = false
        seekInProgress = false
        showPlayerLayer = false
        playerLayerReady = false
    }
}

@MainActor
enum StoryThumbnailPosterCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 20 * 1_024 * 1_024
        return cache
    }()

    static func image(for key: StoryThumbnailPlayerIdentity) -> UIImage? {
        cache.object(forKey: key.cacheKey as NSString)
    }

    static func store(_ image: UIImage, for key: StoryThumbnailPlayerIdentity) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key.cacheKey as NSString, cost: cost)
    }
}
