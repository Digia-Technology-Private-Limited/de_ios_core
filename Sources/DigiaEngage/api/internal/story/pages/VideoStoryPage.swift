import AVFoundation
import SwiftUI

/// One video story in the viewer (T10): the rail's still below, the borrowed player above.
///
/// Borrows under `pageKey` — the key a playing thumbnail hands over on tap, so the viewer
/// reuses the same instance (same key + same URL), reset to the start and unmuted, with the
/// still below covering every frame until the first one lands (never an empty layer). A refused
/// borrow or an evicted holder degrades to the still and tells the viewer to move on (`onFailed`,
/// which the viewer treats like an ended page — the pre-T10 advance-on-failure rule).
/// Mirrors Android `VideoStoryPage`.
///
/// Progress, play/pause and completion all read the owned `MediaVideoState` — never the raw
/// player: progress comes from `positionMs`/`durationMs`, the end from `ended`, play/pause
/// from `playing`. Only the buffering signal (`timeControlStatus`) still reads the borrowed
/// instance, which has no state equivalent. `onReady` still hands the borrowed instance to
/// the host (the harness and the PIP handover read the layer/player), but nothing drives
/// from it anymore.
@MainActor
struct VideoStoryPage: View {
    let item: StoryItemConfig
    let pageKey: String
    let muted: Bool
    let playing: Bool
    let onReady: @MainActor @Sendable (AVPlayer?) -> Void
    let onProgress: @MainActor @Sendable (Double) -> Void
    let onEnded: @MainActor @Sendable () -> Void
    let onBuffering: @MainActor @Sendable (Bool) -> Void
    let onFailed: @MainActor @Sendable () -> Void

    @StateObject private var video: MediaVideoState
    @State private var driverTask: Task<Void, Never>?
    @State private var buffering = false
    /// Latched when the end is reported (see below).
    @State private var ended = false

    init(
        item: StoryItemConfig,
        pageKey: String,
        muted: Bool,
        playing: Bool,
        onReady: @escaping @MainActor @Sendable (AVPlayer?) -> Void,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onEnded: @escaping @MainActor @Sendable () -> Void,
        onBuffering: @escaping @MainActor @Sendable (Bool) -> Void,
        onFailed: @escaping @MainActor @Sendable () -> Void
    ) {
        self.item = item
        self.pageKey = pageKey
        self.muted = muted
        self.playing = playing
        self.onReady = onReady
        self.onProgress = onProgress
        self.onEnded = onEnded
        self.onBuffering = onBuffering
        self.onFailed = onFailed
        _video = StateObject(wrappedValue: MediaVideoState(
            spec: Self.spec(item: item, muted: muted),
            playing: playing,
            keepAliveKey: pageKey,
            poolPriority: .onScreen
        ))
    }

    private static func spec(item: StoryItemConfig, muted: Bool) -> VideoSpec {
        VideoSpec(
            url: item.url,
            fit: item.boxFit.toMediaFit,
            blurHash: item.thumbnailBlurHash,
            posterURL: item.thumbnailImageSource,
            playback: Playback(autoplay: true, muted: muted, startMs: 0)
        )
    }

    var body: some View {
        ZStack {
            Color.black
            StoryThumbnailStill(item: item)
            MediaVideo(state: video)
        }
        .onAppear {
            video.spec = Self.spec(item: item, muted: muted)
            video.playing = playing
            video.onReady = { _ in
                startDriver()
                onReady(video.activePlayer)
            }
            video.onGiveUp = {
                stopDriver()
                // A natural end-of-queue (`AVQueuePlayer` exhausts its single item, so
                // `currentItem` detaches) trips the state's give-up path right after the
                // playhead reaches the end — that is a completed page, not a failure. The
                // detach races the last playhead tick, so neither flag alone is decisive:
                // suppress when the end was reported, the state published it, or the last
                // published playhead is within one tick of the known duration. The pre-R2
                // poll driver only failed a page via `FailedToPlayToEndTime`, never on a
                // natural end; this restores that exact contract (end exactly once,
                // failure only for real faults — and downstream both advance the viewer).
                if !ended, !video.ended, !videoCompletedNaturally() { onFailed() }
            }
        }
        .onChange(of: playing) { _ in video.playing = playing }
        .onChange(of: muted) { _ in video.spec = Self.spec(item: item, muted: muted) }
        .onChange(of: video.ended) { done in
            if done {
                ended = true
                stopDriver()
                onEnded()
            }
        }
        .onDisappear { stopDriver() }
    }

    /// Whether the last published playhead is within one state tick (100 ms, plus the same
    /// 250 ms slop the rail driver uses) of the known duration: a give-up here is the
    /// end-of-queue detach, not a mid-play fault.
    private func videoCompletedNaturally() -> Bool {
        let durationMs = video.durationMs
        return durationMs > 0 && video.positionMs + 250 >= durationMs
    }

    /// Drives progress and buffering from the state: progress from
    /// `positionMs`/`durationMs`, buffering from the borrowed instance's stall signal (no
    /// state equivalent). The end comes from `video.ended`, never from here.
    private func startDriver() {
        stopDriver()
        driverTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                let waiting = video.activePlayer?.timeControlStatus
                    == .waitingToPlayAtSpecifiedRate
                if waiting != buffering {
                    buffering = waiting
                    onBuffering(waiting)
                }
                let durationMs = video.durationMs
                guard durationMs > 0 else { continue }
                onProgress(min(max(
                    Double(video.positionMs) / Double(durationMs), 0), 1))
            }
        }
    }

    private func stopDriver() {
        driverTask?.cancel()
        driverTask = nil
    }
}

private extension StoryItemConfig {
    /// The thumbnail's image source doubles as the viewer poster's campaign URL (D6: posters
    /// render through `MediaImage`), so the page never shows an empty box before its first frame.
    var thumbnailImageSource: String? {
        if case let .image(source, _, _) = thumbnail { return source }
        return nil
    }

    var thumbnailBlurHash: String? {
        if case let .image(_, _, placeholder) = thumbnail,
           placeholder?.type == .blurhash
        {
            return placeholder?.blurHash
        }
        return nil
    }
}
