import AVFoundation
import SwiftUI
import UIKit
internal import DigiaVideoEngine

extension StoryMediaFit {
    var toMediaFit: MediaFit {
        switch self {
        case .cover: .cover
        case .contain: .contain
        case .fill: .fill
        }
    }
}

/// One rail card (T8): obeys play/pause only. A playing video card borrows its player from the
/// pool at the rail rank under `poolKey`, the key the viewer's page borrows under, so a tap hands
/// the same player over. Whenever it has no player it shows its still. Mirrors Android
/// `StoryThumbnail`.
@MainActor
struct StoryThumbnail: View {
    let item: StoryItemConfig
    let poolKey: String
    let playing: Bool
    let repeatWindow: Bool
    let restartGeneration: Int
    let onWindowCompleted: @MainActor () -> Void
    let onFailed: @MainActor () -> Void
    let onSkipped: @MainActor () -> Void

    var body: some View {
        ZStack {
            // Contained media leaves letterbox space: opaque black, as on `main`.
            Color.black
            if item.type == .video, playing {
                StoryThumbnailVideo(
                    item: item,
                    poolKey: poolKey,
                    repeatWindow: repeatWindow,
                    onWindowCompleted: onWindowCompleted,
                    onFailed: onFailed,
                    onSkipped: onSkipped
                )
                // A rail restart starts every card's window again.
                .id(restartGeneration)
            } else {
                StoryThumbnailStill(item: item)
            }
        }
    }
}

/// What a story card or page shows when its video is not playing (or not yet): an image story
/// its picture, a video story its authored thumbnail (image or colour), else the dark backdrop.
/// No frame is cut from the video (Q1). `fitOverride` is the page's fit, which the viewer draws
/// the thumbnail in, as `main` did.
@MainActor
struct StoryThumbnailStill: View {
    let item: StoryItemConfig
    var fitOverride: StoryMediaFit? = nil

    var body: some View {
        ZStack {
            if item.type == .image {
                StoryImage(url: item.url, fit: (fitOverride ?? item.thumbnailBoxFit).toMediaFit)
            } else {
                mediaVideoBackdrop
                switch item.thumbnail {
                case let .color(value):
                    Color(hex: value) ?? mediaVideoBackdrop
                case let .image(source, fit, placeholder):
                    MediaImage(
                        url: source,
                        fit: (fitOverride ?? fit).toMediaFit,
                        blurHash: placeholder?.type == .blurhash ? placeholder?.blurHash : nil,
                        errorContent: AnyView(MediaStill(
                            fit: (fitOverride ?? fit).toMediaFit,
                            blurHash: placeholder?.type == .blurhash ? placeholder?.blurHash : nil))
                    )
                case nil:
                    EmptyView()
                }
            }
        }
        .clipped()
    }
}

/// A story picture through `MediaImage`, on the dark ground only while it loads: once drawn, a
/// letterbox shows the black behind it, as `main`'s story image did.
@MainActor
struct StoryImage: View {
    let url: String
    let fit: MediaFit

    @State private var loaded = false

    var body: some View {
        ZStack {
            if !loaded { mediaVideoBackdrop }
            MediaImage(url: url, fit: fit, onSuccess: { loaded = true }, errorContent: AnyView(EmptyView()))
        }
    }
}

/// A story video through `MediaVideo` on the pool. An authored thumbnail (image or colour) is
/// drawn over the player until the first frame, and a failed video goes back to its still, over
/// `MediaVideo`'s "Video failed" box (T8: a story page shows its still and runs its timer). With no
/// thumbnail a page shows `MediaVideo`'s dark backdrop and spinner rule (T2). A rail tile (`bare`)
/// draws its still beneath a bare `MediaVideo` and never covers it, so the still shows until the
/// first frame and around a contained video after it, as `main`'s tile did (OD-18). After the first
/// frame a page's letterbox is `groundAfterFirstFrame`: black by default (OD-16), #1A1A1A on the
/// inline story's page as on `main` (OD-18).
@MainActor
struct StoryVideoSurface: View {
    let item: StoryItemConfig
    let fit: StoryMediaFit
    var stillFit: StoryMediaFit? = nil
    let poolKey: String
    let priority: PoolPriority
    let muted: Bool
    let playing: Bool
    var loop = false
    var groundAfterFirstFrame: Color = .black
    var bare = false
    let startMs: Int64?
    var onReady: (DigiaVideoPlayer) -> Void = { _ in }
    var onEnded: () -> Void = {}
    var onFailure: () -> Void = {}
    var onLost: () -> Void = {}

    @State private var firstFrameShown = false
    @State private var failed = false

    var body: some View {
        ZStack {
            if bare {
                StoryThumbnailStill(item: item, fitOverride: stillFit)
            }
            MediaVideo(
                url: item.url,
                fit: fit.toMediaFit,
                loop: loop,
                muted: muted,
                autoplay: playing,
                groundAfterFirstFrame: groundAfterFirstFrame,
                bare: bare,
                playerKey: poolKey,
                poolPriority: priority,
                startMs: startMs,
                onFirstFrame: { firstFrameShown = true },
                onReady: onReady,
                onLost: {
                    firstFrameShown = false
                    onLost()
                },
                // The rail skips a refused card's turn and the viewer's pages are Stage 1: neither
                // joins the pool's wait queue.
                waitsForPlayer: false,
                onEnded: onEnded,
                onFailure: {
                    failed = true
                    onFailure()
                }
            )
            if failed || (!bare && !firstFrameShown && item.thumbnail != nil) {
                StoryThumbnailStill(item: item, fitOverride: stillFit)
            }
        }
    }
}

private let storyRailPollInterval: UInt64 = 100_000_000
/// A playing card whose playhead does not move for this long (buffering excepted) is given up on.
private let storyRailStallLimit: TimeInterval = 10
private let storyRailSeekRevealTolerance: Int64 = 250

/// A playing rail video and its take-turns window: from the authored start, for the authored
/// length (or to the end), then the turn passes on, or loops in place when the rail says so.
/// A start the video never reaches falls back to 0 once. A refused borrow or an evicted holder
/// skips the turn (`onSkipped`); only a real failure removes the card (`onFailed`).
@MainActor
private struct StoryThumbnailVideo: View {
    let item: StoryItemConfig
    let poolKey: String
    let repeatWindow: Bool
    let onWindowCompleted: @MainActor () -> Void
    let onFailed: @MainActor () -> Void
    let onSkipped: @MainActor () -> Void

    @State private var driver: Task<Void, Never>?
    @State private var player: DigiaVideoPlayer?
    @State private var startMs: Int64 = 0
    @State private var startRevalidated = false
    @State private var retriedAtZero = false
    @State private var completed = false
    /// A window-start seek is on its way: the playhead still reads the old window.
    @State private var seeking = false
    /// Set when the card unmounts: a late poll belongs to a torn-down turn and stays silent.
    @State private var gone = false

    private var authoredStartMs: Int64 { max(item.thumbnailPlayback.startTimeMs, 0) }
    private var windowMs: Int64? {
        item.thumbnailPlayback.durationMode == .fixed ? item.thumbnailPlayback.durationMs : nil
    }

    var body: some View {
        StoryVideoSurface(
            item: item,
            fit: item.thumbnailBoxFit,
            poolKey: poolKey,
            // A rail card is Stage 2 like any other video on screen (OD-24): no rank of its own.
            priority: .onScreen,
            muted: true,
            playing: true,
            // A lone full window from 0 loops natively; any other window ends through the driver.
            loop: repeatWindow && item.thumbnailPlayback.durationMode == .full && authoredStartMs == 0,
            bare: true,
            startMs: authoredStartMs,
            onReady: { ready in
                player = ready
                startDriver(ready)
            },
            onEnded: { windowEnded() },
            onFailure: {
                stopDriver()
                if !gone { onFailed() }
            },
            onLost: {
                stopDriver()
                if !gone { onSkipped() }
            }
        )
        .onAppear {
            gone = false
            startMs = authoredStartMs
        }
        .onDisappear {
            gone = true
            stopDriver()
        }
    }

    private func windowEnded() {
        guard !completed, !gone, let player else { return }
        // A start past the end of a short video: from the top, once.
        if !retriedAtZero, startMs > 0, !startRevalidated {
            retriedAtZero = true
            startMs = 0
            seek(player, to: 0, thenPlay: true)
            return
        }
        if repeatWindow {
            seek(player, to: startMs, thenPlay: true)
            return
        }
        completed = true
        stopDriver()
        onWindowCompleted()
    }

    private func startDriver(_ video: DigiaVideoPlayer) {
        stopDriver()
        let player = video.avPlayer
        driver = Task { @MainActor in
            var lastPosition = milliseconds(player.currentTime())
            var lastProgressAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: storyRailPollInterval)
                guard !Task.isCancelled, !gone else { return }
                if seeking { continue }
                let position = milliseconds(player.currentTime())
                let duration = player.currentItem.map { milliseconds($0.duration) } ?? 0
                if !startRevalidated, duration > 0 {
                    startRevalidated = true
                    if startMs > 0, startMs >= duration, !retriedAtZero {
                        retriedAtZero = true
                        startMs = 0
                        seek(video, to: 0, thenPlay: true)
                        lastProgressAt = ProcessInfo.processInfo.systemUptime
                        continue
                    }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if position != lastPosition {
                    lastPosition = position
                    lastProgressAt = now
                } else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                    lastProgressAt = now
                } else if player.rate > 0, now - lastProgressAt >= storyRailStallLimit {
                    if !retriedAtZero, startMs > 0 {
                        // A start the video never reaches (deeper than its frames): from the top.
                        retriedAtZero = true
                        startMs = 0
                        seek(video, to: 0, thenPlay: true)
                        lastProgressAt = now
                        continue
                    }
                    stopDriver()
                    onFailed()
                    return
                }
                let reachedStart = startMs == 0 || position + storyRailSeekRevealTolerance >= startMs
                if reachedStart, let windowMs, position - startMs >= windowMs {
                    windowEnded()
                    if completed { return }
                }
            }
        }
    }

    private func seek(_ video: DigiaVideoPlayer, to ms: Int64, thenPlay: Bool) {
        seeking = true
        video.avPlayer.seek(to: CMTime(value: ms, timescale: 1_000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in
                seeking = false
                if thenPlay, !gone { video.play() }
            }
        }
    }

    private func stopDriver() {
        driver?.cancel()
        driver = nil
    }

    private func milliseconds(_ time: CMTime) -> Int64 {
        guard time.isNumeric, time.seconds.isFinite else { return 0 }
        return Int64(time.seconds * 1_000)
    }
}
