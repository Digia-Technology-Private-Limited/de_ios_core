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
    let shouldPlay: Bool
    let reduceMotion: Bool
    let mode: ThumbnailVideoPlaybackMode
    let playableIndices: Set<Int>
    let restartGeneration: Int
}

struct StoryThumbnailPlayerIdentity: Hashable {
    let itemType: String
    let url: String
    let startTimeMs: Int64
    let durationMode: String
    let durationMs: Int64
    let thumbnailType: String
    let imageSrc: String
    let imageFit: String
    let blurHash: String
    let color: String

    var cacheKey: String {
        [
            itemType,
            url,
            String(startTimeMs),
            durationMode,
            String(durationMs),
            thumbnailType,
            imageSrc,
            imageFit,
            blurHash,
            color,
        ]
        .map { "\($0.utf8.count):\($0)" }
        .joined()
    }
}

func thumbnailPlayerIdentity(_ item: StoryItemConfig) -> StoryThumbnailPlayerIdentity {
    StoryThumbnailPlayerIdentity(
        itemType: item.type,
        url: item.url,
        startTimeMs: item.thumbnailPlayback.startTimeMs,
        durationMode: item.thumbnailPlayback.durationMode.rawValue,
        durationMs:
            item.thumbnailPlayback.durationMode == .fixed
                ? item.thumbnailPlayback.durationMs ?? 0
                : 0,
        thumbnailType: item.thumbnail?.type.rawValue ?? "",
        imageSrc: item.thumbnail?.imageSrc ?? "",
        imageFit: item.thumbnail?.fit.rawValue ?? "",
        blurHash: item.thumbnail?.placeholder?.blurHash ?? "",
        color: item.thumbnail?.color ?? ""
    )
}

struct StoryThumbnailPlaceholderView: View {
    let thumbnail: StoryThumbnailConfig?

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.10)
            switch thumbnail?.type {
            case .color:
                Color(hex: thumbnail?.color ?? "") ?? Color(red: 0.10, green: 0.10, blue: 0.10)
            case .image:
                if let thumbnail,
                   let imageSrc = thumbnail.imageSrc,
                   let url = URL(string: imageSrc)
                {
                    fitted(
                        DigiaCachedImageView(
                            url: url,
                            placeholder: AnyView(
                                BlurHashPlaceholderView(placeholder: thumbnail.placeholder)
                            )
                        ),
                        fit: thumbnail.fit
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
        fit: StoryThumbnailImageFit
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
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            }
            if let player = model.player {
                InlineStoryPlayerLayer(
                    player: player,
                    gravity: .resizeAspectFill,
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
        shouldPlay: false,
        reduceMotion: false,
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
    private var watchdogTask: Task<Void, Never>?
    private var watchdogGeneration: UInt = 0
    private var terminalFailurePending = false
    private var terminalFailureReported = false
    private var seekFallbackTask: Task<Void, Never>?
    private var seekGeneration: UInt = 0
    private var imageGenerator: AVAssetImageGenerator?
    private var imageGenerationID: UUID?
    private var onWindowCompleted: () -> Void = {}
    private var onFailed: () -> Void = {}
    private var playerLayerReady = false

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
        if item.thumbnail != nil, !state.shouldPlay {
            if bundle != nil {
                tearDown()
            }
            return
        }
        prepareIfNeeded()

        if terminalFailureReported { return }
        if state.shouldPlay {
            startWatchdog()
        } else {
            stopWatchdog()
        }
        guard let player else { return }
        if restartRequested {
            completionHandled = false
            player.pause()
            guard startPrepared else { return }
            seekToStart(retryAtZero: true) {
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
            if !state.eligible || state.reduceMotion {
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
        let cacheKey = thumbnailPlayerIdentity(item)
        let next = StoryThumbnailWarmPlayerCache.take(cacheKey)
            ?? DigiaVideoPlaybackBundle.make(url: url, looping: false)
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

    private func preparePoster(from asset: AVAsset?) {
        let cacheKey = thumbnailPlayerIdentity(item)
        guard item.thumbnail == nil, poster == nil, let asset else { return }
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
        stopWatchdog()

        if state.shouldPlay,
           shouldRepeatThumbnailPlaybackWindow(
               mode: state.mode,
               eligibleVideoCount: state.playableIndices.count
           )
        {
            seekToStart(retryAtZero: true) {
                guard self.state.shouldPlay else { return }
                self.completionHandled = false
                player.play()
            }
            startWatchdog()
        } else {
            // The outgoing player's reset is best-effort background cleanup.
            // Coordinator advancement must not depend on AVPlayer invoking a
            // remote seek callback; some assets move currentTime successfully
            // without ever calling that completion handler.
            onWindowCompleted()
            seekToStart(retryAtZero: true)
        }
    }

    private func resetToStart() {
        seekToStart(retryAtZero: true)
    }

    private func seekToStart(
        retryAtZero: Bool = false,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        showPlayerLayer = false
        seekGeneration &+= 1
        let generation = seekGeneration
        seekFallbackTask?.cancel()
        seekFallbackTask = nil
        guard let player else {
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
                    completion: completion
                )
            }
        }
        seekFallbackTask = Task { [weak self, weak expectedPlayer] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self, let expectedPlayer else { return }
            guard self.seekGeneration == generation, self.player === expectedPlayer else { return }
            let target = Double(self.effectiveStartMs) / 1_000
            let position = expectedPlayer.currentTime().seconds
            let reachedTarget = position.isFinite && abs(position - target) <= 0.25
            guard reachedTarget else { return }
            self.finishSeek(
                generation: generation,
                expectedPlayer: expectedPlayer,
                succeeded: reachedTarget,
                retryAtZero: retryAtZero,
                completion: completion
            )
        }
    }

    private func finishSeek(
        generation: UInt,
        expectedPlayer: AVPlayer,
        succeeded: Bool,
        retryAtZero: Bool,
        completion: (@MainActor @Sendable () -> Void)?
    ) {
        guard seekGeneration == generation, player === expectedPlayer else { return }
        seekGeneration &+= 1
        seekFallbackTask?.cancel()
        seekFallbackTask = nil
        if succeeded {
            completion?()
        } else if retryAtZero, effectiveStartMs != 0 {
            effectiveStartMs = 0
            seekToStart(completion: completion)
        }
    }

    private func handleTerminalFailure() {
        guard !terminalFailurePending, !terminalFailureReported else { return }
        terminalFailurePending = true
        player?.pause()
        showPlayerLayer = false
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        imageGenerationID = nil
        reportTerminalFailure()
    }

    private func reportTerminalFailure() {
        guard !terminalFailureReported else { return }
        terminalFailureReported = true
        terminalFailurePending = false
        stopWatchdog()
        onFailed()
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogGeneration &+= 1
        let generation = watchdogGeneration
        watchdogTask = Task { [weak self] in
            var lastPosition = self?.player?.currentTime().seconds ?? 0
            var stalled = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                guard !Task.isCancelled, self.state.shouldPlay else { break }
                let position = self.player?.currentTime().seconds ?? lastPosition
                if position > lastPosition + 0.01 {
                    lastPosition = position
                    stalled = 0
                } else {
                    stalled += 0.5
                    if stalled >= thumbnailPlaybackStallSeconds {
                        self.handleTerminalFailure()
                        break
                    }
                }
            }
            guard let self, self.watchdogGeneration == generation else { return }
            self.watchdogTask = nil
        }
    }

    private func stopWatchdog() {
        watchdogGeneration &+= 1
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func playerLayerDidBecomeReady() {
        playerLayerReady = true
        revealPlayerLayerIfReady(positionMs: currentPositionMs())
    }

    private func revealPlayerLayerIfReady(positionMs: Int64) {
        guard state.shouldPlay,
              startPrepared,
              playerLayerReady,
              positionMs > effectiveStartMs + 10
        else {
            return
        }
        showPlayerLayer = true
    }

    private func currentPositionMs() -> Int64 {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite && seconds > 0 ? Int64(seconds * 1_000) : 0
    }

    func tearDown() {
        stopWatchdog()
        seekGeneration &+= 1
        seekFallbackTask?.cancel()
        seekFallbackTask = nil
        imageGenerator?.cancelAllCGImageGeneration()
        imageGenerator = nil
        imageGenerationID = nil
        statusObserver?.invalidate()
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
        timeObserver = nil
        endObserver = nil
        failObserver = nil
        player?.pause()
        if let bundle {
            if terminalFailurePending || terminalFailureReported || item.thumbnail != nil {
                StoryThumbnailWarmPlayerCache.release(bundle)
            } else {
                StoryThumbnailWarmPlayerCache.store(
                    bundle,
                    for: thumbnailPlayerIdentity(item)
                )
            }
        }
        player = nil
        bundle = nil
        startPrepared = false
        showPlayerLayer = false
        playerLayerReady = false
    }
}

@MainActor
private enum StoryThumbnailWarmPlayerCache {
    private static let countLimit = 1
    private static var entries: [StoryThumbnailPlayerIdentity: DigiaVideoPlaybackBundle] = [:]
    private static var recency: [StoryThumbnailPlayerIdentity] = []
    private static var invalidated: Set<StoryThumbnailPlayerIdentity> = []

    static func take(_ key: StoryThumbnailPlayerIdentity) -> DigiaVideoPlaybackBundle? {
        recency.removeAll { $0 == key }
        return entries.removeValue(forKey: key)
    }

    static func store(
        _ bundle: DigiaVideoPlaybackBundle,
        for key: StoryThumbnailPlayerIdentity
    ) {
        bundle.player.pause()
        if invalidated.remove(key) != nil {
            release(bundle)
            return
        }
        if let replaced = entries.updateValue(bundle, forKey: key) {
            release(replaced)
        }
        recency.removeAll { $0 == key }
        recency.append(key)

        while recency.count > countLimit {
            let oldestKey = recency.removeFirst()
            if let evicted = entries.removeValue(forKey: oldestKey) {
                release(evicted)
            }
        }
    }

    static func invalidate(_ key: StoryThumbnailPlayerIdentity) {
        invalidated.insert(key)
        recency.removeAll { $0 == key }
        if let bundle = entries.removeValue(forKey: key) {
            release(bundle)
        }
        DispatchQueue.main.async {
            invalidated.remove(key)
        }
    }

    static func release(_ bundle: DigiaVideoPlaybackBundle) {
        bundle.looper?.disableLooping()
        bundle.player.pause()
        if let queuePlayer = bundle.player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            bundle.player.replaceCurrentItem(with: nil)
        }
    }
}

@MainActor
func invalidateStoryThumbnailWarmPlayer(_ identity: StoryThumbnailPlayerIdentity) {
    StoryThumbnailWarmPlayerCache.invalidate(identity)
}

private enum StoryThumbnailPosterCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
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
