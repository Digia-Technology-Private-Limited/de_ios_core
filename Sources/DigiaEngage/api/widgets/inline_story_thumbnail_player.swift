import AVFoundation
import Combine
import SwiftUI

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
            if let player = model.player {
                InlineStoryPlayerLayer(player: player, gravity: .resizeAspectFill)
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

    private let item: StoryItemConfig
    private var bundle: DigiaVideoPlaybackBundle?
    private var state = ThumbnailPlaybackViewState(
        eligible: false,
        shouldPlay: false,
        reduceMotion: false,
        mode: .simultaneous,
        playableIndices: []
    )
    private var effectiveStartMs: Int64 = 0
    private var startPrepared = false
    private var completionHandled = false
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var watchdogTask: Task<Void, Never>?
    private var onWindowCompleted: () -> Void = {}
    private var onFailed: () -> Void = {}

    init(item: StoryItemConfig) {
        self.item = item
    }

    func update(
        state: ThumbnailPlaybackViewState,
        onWindowCompleted: @escaping () -> Void,
        onFailed: @escaping () -> Void
    ) {
        let wasPlaying = self.state.shouldPlay
        self.state = state
        self.onWindowCompleted = onWindowCompleted
        self.onFailed = onFailed
        prepareIfNeeded()

        guard let player else { return }
        if state.shouldPlay {
            if !wasPlaying {
                completionHandled = false
                player.play()
            }
            startWatchdog()
        } else {
            player.pause()
            stopWatchdog()
            if !state.eligible || state.reduceMotion {
                resetToStart()
            }
        }
    }

    private func prepareIfNeeded() {
        guard bundle == nil else { return }
        guard let url = URL(string: item.url) else {
            onFailed()
            return
        }
        let next = DigiaVideoPlaybackBundle.make(url: url, looping: false)
        next.player.isMuted = true
        bundle = next
        player = next.player

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
                        self.onFailed()
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
                Task { @MainActor in self?.onFailed() }
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
                self.startWatchdog()
            }
        }
    }

    private func completeWindow() {
        guard !completionHandled, let player else { return }
        completionHandled = true
        player.pause()
        stopWatchdog()
        seekToStart(retryAtZero: true) {
            if self.state.shouldPlay &&
                shouldRepeatThumbnailPlaybackWindow(
                    mode: self.state.mode,
                    eligibleVideoCount: self.state.playableIndices.count
                )
            {
                self.completionHandled = false
                player.play()
                self.startWatchdog()
            } else {
                self.onWindowCompleted()
            }
        }
    }

    private func resetToStart() {
        seekToStart(retryAtZero: true)
    }

    private func seekToStart(
        retryAtZero: Bool = false,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let player else {
            completion?()
            return
        }
        let expectedPlayer = player
        let time = CMTime(value: effectiveStartMs, timescale: 1_000)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] succeeded in
            Task { @MainActor in
                guard let self, self.player === expectedPlayer else { return }
                if succeeded {
                    completion?()
                } else if retryAtZero, self.effectiveStartMs != 0 {
                    self.effectiveStartMs = 0
                    self.seekToStart(completion: completion)
                } else {
                    self.onFailed()
                }
            }
        }
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
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
                        self.onFailed()
                        break
                    }
                }
            }
            self?.watchdogTask = nil
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    func tearDown() {
        stopWatchdog()
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
        bundle?.looper?.disableLooping()
        player?.pause()
        if let queuePlayer = player as? AVQueuePlayer {
            queuePlayer.removeAllItems()
        } else {
            player?.replaceCurrentItem(with: nil)
        }
        player = nil
        bundle = nil
        startPrepared = false
    }
}
