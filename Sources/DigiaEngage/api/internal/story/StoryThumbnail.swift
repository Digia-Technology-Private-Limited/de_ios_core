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
/// Image thumbnails render through `MediaImage` (D6); a video story with no thumbnail image
/// keeps the dark backdrop until its first frame (Q1 still open — the generated-frame poster
/// path stays working underneath the player, repointed at the D2 asset).
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
                MediaImage(spec: MediaSpec(
                    url: source,
                    fit: fit.toMediaFit,
                    blurHash: placeholder?.type == .blurhash ? placeholder?.blurHash : nil
                ))
            case nil:
                if item.type != .video {
                    MediaImage(spec: MediaSpec(url: item.url, fit: item.thumbnailBoxFit.toMediaFit))
                }
            }
        }
        .clipped()
    }
}

/// A playing rail video: a pool-borrowed `MediaVideo` plus its take-turns window driver.
/// The still below covers every frame until the first one lands (never an empty layer).
@MainActor
private struct StoryThumbnailVideo: View {
    let item: StoryItemConfig
    let keepAliveKey: String
    let playing: Bool
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

    @State private var player: AVPlayer?
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

    private var startMs: Int64 { max(item.thumbnailPlayback.startTimeMs, 0) }
    private var windowMs: Int64? {
        item.thumbnailPlayback.durationMode == .fixed ? item.thumbnailPlayback.durationMs : nil
    }

    private var spec: MediaSpec {
        MediaSpec(
            url: item.url,
            fit: item.thumbnailBoxFit.toMediaFit,
            loop: repeatWindow
                && item.thumbnailPlayback.durationMode == .full
                && startMs == 0,
            autoplay: true,
            muted: true,
            startMs: Int(startMs)
        )
    }

    var body: some View {
        ZStack {
            // Q1 poster path, untouched: the generated frame (D2 asset) below the player.
            StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            if item.thumbnail == nil, let poster = StoryVideoPosterCache.image(
                for: StoryVideoPosterIdentity(url: item.url, frameMs: startMs)
            ) {
                StoryPosterImage(image: poster, fit: item.thumbnailBoxFit)
            }
            MediaVideo(
                spec: spec,
                keepAliveKey: keepAliveKey,
                poolPriority: .railThumb,
                playing: playing && !backgrounded,
                onReady: { ready in
                    player = ready
                    errored = false
                    startDriver(player: ready)
                },
                onError: { _ in errored = true },
                onGiveUp: {
                    stopDriver()
                    if !gone {
                        if errored { onFailed() } else { onEvicted() }
                    }
                }
            )
        }
        .id(reappearGeneration)
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
    private func startDriver(player: AVPlayer) {
        stopDriver()
        driverTask = Task { @MainActor in
            var lastPosition = CMTime.zero
            var lastProgressAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled else { return }
                let position = player.currentTime()
                let duration = player.currentItem?.duration ?? .indefinite
                let durationMs = duration.isNumeric && duration.seconds.isFinite
                    ? Int64(duration.seconds * 1_000) : 0
                let positionMs = position.isNumeric && position.seconds.isFinite
                    ? Int64(position.seconds * 1_000) : 0
                if !startRevalidated, durationMs > 0 {
                    startRevalidated = true
                    if startMs > 0, startMs >= durationMs, !retriedAtZero {
                        retriedAtZero = true
                        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                        guard !Task.isCancelled else { return }
                    }
                }
                if position != lastPosition {
                    lastPosition = position
                    lastProgressAt = Date()
                } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    lastProgressAt = Date()
                } else if player.rate > 0, Date().timeIntervalSince(lastProgressAt) >= 10 {
                    if !retriedAtZero, startMs > 0 {
                        retriedAtZero = true
                        await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
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
                    && player.timeControlStatus != .waitingToPlayAtSpecifiedRate
                let reachedStart = effectiveStart == 0 || positionMs + 250 >= effectiveStart
                if reachedStart, windowOver || streamEnded {
                    if !completed {
                        completed = true
                        if repeatWindow {
                            await player.seek(to: CMTime(
                                value: effectiveStart * 1_000, timescale: 1_000_000),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                            guard !Task.isCancelled else { return }
                            player.play()
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

    private func stopDriver() {
        driverTask?.cancel()
        driverTask = nil
    }
}
