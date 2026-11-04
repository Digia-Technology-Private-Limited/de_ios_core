import AVFoundation
import SwiftUI
import UIKit

extension StoryMediaFit {
    var toMediaFit: MediaFit {
        switch self {
        case .cover: .cover
        case .contain: .contain
        case .fill: .fill
        }
    }
}

/// One rail card (T10): obeys play/pause only. Renders through `MediaImage` / `MediaVideo`
/// with `keepAliveKey story-<index>` (namespaced by the ambient campaign key, so a card never
/// shares a holder with another campaign's card at the same index), so tapping a playing video
/// hands the same pool instance to the viewer; shows its still whenever it has no player.
///
/// A tap on a playing video hands over under `handoffKey` (same key + same URL → same player,
/// no frame gap); a tap on a still opens with no handoff and the viewer builds fresh.
/// `handedOver` keeps the card mounted (but never unmutes it) while the viewer is open.
@MainActor
struct StoryThumbnail: View {
    let item: StoryItemConfig
    let index: Int
    let playing: Bool
    let handedOver: Bool
    let repeatWindow: Bool
    let reappearGeneration: Int
    let namespace: String?
    let onWindowCompleted: @MainActor @Sendable () -> Void
    let onFailed: @MainActor @Sendable () -> Void
    let onEvicted: @MainActor @Sendable () -> Void
    let onOpen: @MainActor @Sendable (Int, String?) -> Void

    private var keepAliveKey: String { storyPoolKey(namespace: namespace, index: index) }
    private var isVideo: Bool { item.type == .video }

    var body: some View {
        ZStack {
            StoryThumbnailStill(item: item)
            if isVideo, playing || handedOver {
                StoryThumbnailVideo(
                    item: item,
                    keepAliveKey: keepAliveKey,
                    playing: playing || handedOver,
                    handedOver: handedOver,
                    repeatWindow: repeatWindow,
                    reappearGeneration: reappearGeneration,
                    onWindowCompleted: onWindowCompleted,
                    onFailed: onFailed,
                    onEvicted: onEvicted
                )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isVideo, playing || handedOver {
                onOpen(index, keepAliveKey)
            } else {
                onOpen(index, nil)
            }
        }
    }
}

/// What a rail card shows when its video is not playing (or while it loads): never empty.
/// Image thumbnails render through `MediaImage` (D6) with their BlurHash; a video story with
/// no thumbnail image keeps the dark backdrop until its first frame (Q1: no frame is cut from
/// the video, so nothing is downloaded twice).
@MainActor
struct StoryThumbnailStill: View {
    let item: StoryItemConfig

    var body: some View {
        ZStack {
            Color.mediaBackdrop
            switch item.thumbnail {
            case let .color(value):
                Color(hex: value) ?? Color.mediaBackdrop
            case let .image(source, fit, placeholder):
                MediaImage(spec: ImageSpec(
                    url: source,
                    fit: fit.toMediaFit,
                    blurHash: placeholder?.type == .blurhash ? placeholder?.blurHash : nil
                ))
            case nil:
                if item.type != .video {
                    MediaImage(spec: ImageSpec(url: item.url, fit: item.thumbnailBoxFit.toMediaFit))
                }
            }
        }
        .clipped()
    }
}

/// A playing rail video: a pool-borrowed `MediaVideo` plus its take-turns window driver.
/// The still below covers every frame until the first one lands (never an empty layer).
///
/// Progress, play/pause and completion all read the owned `MediaVideoState` — never the raw
/// player: the window driver polls `positionMs`/`durationMs`, play/pause flows through
/// `playing`, and only the stall liveness check (`rate`, `waitingToPlay`) still reads the
/// borrowed instance, which has no state equivalent. Window-start seeks go to the borrowed
/// instance directly — `seekToStart` always targets zero, but a thumbnail window may start
/// into the clip.
@MainActor
private struct StoryThumbnailVideo: View {
    let item: StoryItemConfig
    let keepAliveKey: String
    let playing: Bool
    /// The rail handed this borrow to the viewer on tap: the viewer's lease under the same
    /// key now owns the holder, so this showing's dispose must not free it (R2-STORY wiring
    /// for the `borrowHandedOver` default the reviewer flagged). Read fresh at dispose time
    /// — synced into the state below on every change.
    let handedOver: Bool
    let repeatWindow: Bool
    let reappearGeneration: Int
    let onWindowCompleted: @MainActor @Sendable () -> Void
    let onFailed: @MainActor @Sendable () -> Void
    /// The borrow was lost without a failure cause (pool eviction or a causeless give-up):
    /// advance past the card like a completion, but keep it eligible — unlike a genuine
    /// failure, a lost borrow says nothing about the content, so the rotation must not
    /// drop the card. Genuine failures (bad URL, decode, network) always carry a cause
    /// through `onError` first and keep routing to `onFailed`.
    let onEvicted: @MainActor @Sendable () -> Void

    @StateObject private var video: MediaVideoState
    @State private var backgrounded = false
    @State private var driverTask: Task<Void, Never>?
    @State private var completed = false
    @State private var startRevalidated = false
    @State private var retriedAtZero = false
    /// Set when the card unmounts. A completion or failure observed after this point belongs
    /// to a torn-down showing (the pool hands the freed player to the next card while the
    /// old driver's last poll is still in flight): reporting it would mark a healthy,
    /// already-completed card as failed and drop it from the rotation. The rail moved on via
    /// the live showing; the dead one stays silent.
    @State private var gone = false
    /// Whether this showing already reported a caused failure through `onError`. Genuine
    /// failures (bad URL, decode, network) always carry a cause first; a give-up with no
    /// preceding cause is a lost borrow (pool eviction or the silent path), not a verdict
    /// on the content. Reset on every new borrow.
    @State private var errored = false

    init(
        item: StoryItemConfig,
        keepAliveKey: String,
        playing: Bool,
        handedOver: Bool,
        repeatWindow: Bool,
        reappearGeneration: Int,
        onWindowCompleted: @escaping @MainActor @Sendable () -> Void,
        onFailed: @escaping @MainActor @Sendable () -> Void,
        onEvicted: @escaping @MainActor @Sendable () -> Void
    ) {
        self.item = item
        self.keepAliveKey = keepAliveKey
        self.playing = playing
        self.handedOver = handedOver
        self.repeatWindow = repeatWindow
        self.reappearGeneration = reappearGeneration
        self.onWindowCompleted = onWindowCompleted
        self.onFailed = onFailed
        self.onEvicted = onEvicted
        _video = StateObject(wrappedValue: MediaVideoState(
            spec: Self.spec(item: item, repeatWindow: repeatWindow),
            playing: playing,
            keepAliveKey: keepAliveKey,
            poolPriority: .railThumb,
            borrowHandedOver: { handedOver }
        ))
    }

    private var startMs: Int64 { max(item.thumbnailPlayback.startTimeMs, 0) }
    private var windowMs: Int64? {
        item.thumbnailPlayback.durationMode == .fixed ? item.thumbnailPlayback.durationMs : nil
    }

    private static func spec(item: StoryItemConfig, repeatWindow: Bool) -> VideoSpec {
        let startMs = max(item.thumbnailPlayback.startTimeMs, 0)
        return VideoSpec(
            url: item.url,
            fit: item.thumbnailBoxFit.toMediaFit,
            playback: Playback(
                loop: repeatWindow
                    && item.thumbnailPlayback.durationMode == .full
                    && startMs == 0,
                autoplay: true,
                muted: true,
                startMs: Int(startMs)
            )
        )
    }

    private var spec: VideoSpec {
        Self.spec(item: item, repeatWindow: repeatWindow)
    }

    var body: some View {
        ZStack {
            StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            MediaVideo(state: video)
        }
        .id(reappearGeneration)
        .onAppear {
            video.spec = spec
            video.playing = playing && !backgrounded
            video.onReady = { _ in
                errored = false
                startDriver()
            }
            video.onError = { _ in errored = true }
            video.onGiveUp = {
                stopDriver()
                if !gone {
                    if errored { onFailed() } else { onEvicted() }
                }
            }
        }
        .onChange(of: playing) { _ in video.playing = playing && !backgrounded }
        .onChange(of: backgrounded) { _ in video.playing = playing && !backgrounded }
        // The tap lands in the same pass as a potential unmount: keep the handover read
        // fresh so a dispose while handed over never frees the viewer's holder.
        .onChange(of: handedOver) { _ in video.borrowHandedOver = { handedOver } }
        .onChange(of: video.firstFrameShown) { shown in
            if shown {
                errored = false
                startDriver()
            }
        }
        .onDisappear {
            gone = true
            stopDriver()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willResignActiveNotification
        )) { _ in backgrounded = true }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didBecomeActiveNotification
        )) { _ in backgrounded = false }
    }

    /// A remount (viewer close, config change) re-borrows under the same key: take-over seeks
    /// back to the window start and replays, so the rail resumes instead of freezing.
    ///
    /// Reads the state's playhead publishers, never the raw player: `positionMs`/`durationMs`
    /// drive the window math; only the stall liveness check (`rate`, `waitingToPlay`) reads
    /// the borrowed instance, which has no state equivalent. Window-start seeks go to the
    /// borrowed instance directly — `seekToStart` always targets zero, but a thumbnail window
    /// may start into the clip.
    private func startDriver() {
        stopDriver()
        driverTask = Task { @MainActor in
            var lastPosition: Int64 = 0
            var lastProgressAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                let durationMs = video.durationMs
                let positionMs = video.positionMs
                if !startRevalidated, durationMs > 0 {
                    startRevalidated = true
                    if startMs > 0, startMs >= durationMs, !retriedAtZero {
                        retriedAtZero = true
                        await seekActivePlayer(to: 0)
                        guard !Task.isCancelled else { return }
                    }
                }
                if positionMs != lastPosition {
                    lastPosition = positionMs
                    lastProgressAt = Date()
                } else if video.activePlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    lastProgressAt = Date()
                } else if (video.activePlayer?.rate ?? 0) > 0,
                          Date().timeIntervalSince(lastProgressAt) >= 10 {
                    if !retriedAtZero, startMs > 0 {
                        retriedAtZero = true
                        await seekActivePlayer(to: 0)
                        guard !Task.isCancelled else { return }
                        lastProgressAt = Date()
                        continue
                    }
                    stopDriver()
                    if !gone { onFailed() }
                    return
                }
                let effectiveStart = retriedAtZero ? 0 : startMs
                let windowOver = windowMs.map { positionMs - effectiveStart >= $0 } ?? false
                let streamEnded = durationMs > 0 && positionMs >= durationMs
                    && video.activePlayer?.timeControlStatus != .waitingToPlayAtSpecifiedRate
                let reachedStart = effectiveStart == 0 || positionMs + 250 >= effectiveStart
                if reachedStart, windowOver || streamEnded {
                    if !completed {
                        completed = true
                        if repeatWindow {
                            await seekActivePlayer(to: effectiveStart)
                            guard !Task.isCancelled else { return }
                            video.play()
                            completed = false
                        } else {
                            stopDriver()
                            if !gone { onWindowCompleted() }
                            return
                        }
                    }
                }
            }
        }
    }

    /// Seeks the borrowed instance to a window-start millisecond offset. `MediaVideoState`
    /// only offers `seekToStart` (zero), but a thumbnail window may start into the clip, so
    /// the window math seeks here directly. Reads/writes nothing the state's take-over did
    /// not already apply.
    private func seekActivePlayer(to ms: Int64) async {
        guard let player = video.activePlayer else { return }
        await player.seek(
            to: CMTime(value: ms * 1_000, timescale: 1_000_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func stopDriver() {
        driverTask?.cancel()
        driverTask = nil
    }
}
