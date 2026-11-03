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

    @State private var player: AVPlayer?
    @State private var driverTask: Task<Void, Never>?
    @State private var ended = false
    @State private var buffering = false

    private var spec: VideoSpec {
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
            MediaVideo(
                spec: spec,
                keepAliveKey: pageKey,
                poolPriority: .onScreen,
                playing: playing,
                onReady: { ready in
                    player = ready
                    startDriver(player: ready)
                    onReady(ready)
                },
                onGiveUp: {
                    stopDriver()
                    onFailed()
                }
            )
        }
        .onDisappear { stopDriver() }
    }

    private func startDriver(player: AVPlayer) {
        stopDriver()
        driverTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled else { return }
                let position = player.currentTime()
                let duration = player.currentItem?.duration ?? .indefinite
                let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if waiting != buffering {
                    buffering = waiting
                    onBuffering(waiting)
                }
                guard position.isNumeric, position.seconds.isFinite,
                      duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0
                else { continue }
                onProgress(min(max(position.seconds / duration.seconds, 0), 1))
                if !ended, position.seconds >= duration.seconds {
                    ended = true
                    stopDriver()
                    onEnded()
                    return
                }
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
