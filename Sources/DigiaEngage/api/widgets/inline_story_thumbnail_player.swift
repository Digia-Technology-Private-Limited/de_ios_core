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

struct StoryPosterImage: View {
    let image: UIImage
    let fit: StoryMediaFit

    @ViewBuilder
    var body: some View {
        let content = Image(uiImage: image).resizable()
        if fit.stretchesImage {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content.aspectRatio(contentMode: fit.imageContentMode)
        }
    }
}

@MainActor
struct StoryThumbnailVideoView: View {
    let item: StoryItemConfig
    let state: ThumbnailPlaybackViewState
    let onWindowCompleted: @MainActor @Sendable () -> Void
    let onFailed: @MainActor @Sendable () -> Void

    @StateObject private var playback: StoryVideoPlayback

    init(
        item: StoryItemConfig,
        state: ThumbnailPlaybackViewState,
        onWindowCompleted: @escaping @MainActor @Sendable () -> Void,
        onFailed: @escaping @MainActor @Sendable () -> Void
    ) {
        self.item = item
        self.state = state
        self.onWindowCompleted = onWindowCompleted
        self.onFailed = onFailed
        _playback = StateObject(wrappedValue: StoryVideoPlayback(
            urlString: item.url,
            purpose: .thumbnail(item)
        ))
    }

    var body: some View {
        ZStack {
            Color.black
            StoryThumbnailPlaceholderView(thumbnail: item.thumbnail)
            if item.thumbnail == nil, let poster = playback.poster {
                StoryPosterImage(image: poster, fit: item.thumbnailBoxFit)
            }
            if let player = playback.player {
                InlineStoryPlayerLayer(
                    player: player,
                    gravity: item.thumbnailBoxFit.videoGravity,
                    onReadyForDisplay: playback.playerLayerDidBecomeReady
                )
                .opacity(playback.showPlayerLayer ? 1 : 0)
            }
        }
        .onAppear(perform: updatePlayback)
        .onChange(of: state) { _ in updatePlayback() }
        .onDisappear { playback.tearDown() }
    }

    private func updatePlayback() {
        playback.update(
            state: StoryVideoPlaybackState(
                demand: loadDemand,
                active: state.shouldPlay,
                muted: true,
                repeatWindow: shouldRepeatThumbnailPlaybackWindow(
                    mode: state.mode,
                    eligibleVideoCount: state.playableIndices.count
                ),
                restartGeneration: state.restartGeneration
            ),
            events: StoryVideoPlaybackEvents(
                onEnded: onWindowCompleted,
                onFailed: onFailed
            )
        )
    }

    private var loadDemand: StoryVideoLoadDemand {
        guard state.canLoad else { return .none }
        if state.scheduled {
            return .playback(state.cachePriority ?? .scheduled)
        }
        if item.thumbnail == nil, let priority = state.cachePriority {
            return .poster(priority)
        }
        return .none
    }
}
