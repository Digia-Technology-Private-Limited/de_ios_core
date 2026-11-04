import AVFoundation
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

/// The dark tile a rail card shows under its media. A video story with no thumbnail image keeps
/// this backdrop until its first frame (Q1: no frame is cut from the video).
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
                    let effectiveFit = fitOverride ?? fit
                    fitted(
                        DigiaCachedImageView(
                            url: url,
                            placeholder: AnyView(
                                BlurHashPlaceholderView(placeholder: placeholder, fit: effectiveFit.rawValue)
                            )
                        ),
                        fit: effectiveFit
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

/// The raw video rendering surface shared by the story rail and the floater/PIP media view:
/// a transparent `AVPlayerLayer` that shows through to the still below until the first frame.
struct InlineStoryPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var onReadyForDisplay: (() -> Void)?

    func makeUIView(context _: Context) -> InlineStoryPlayerContainer {
        let view = InlineStoryPlayerContainer()
        view.configure(
            player: player,
            gravity: gravity,
            onReadyForDisplay: onReadyForDisplay
        )
        return view
    }

    func updateUIView(_ uiView: InlineStoryPlayerContainer, context _: Context) {
        uiView.configure(
            player: player,
            gravity: gravity,
            onReadyForDisplay: onReadyForDisplay
        )
    }

    static func dismantleUIView(_ uiView: InlineStoryPlayerContainer, coordinator _: Void) {
        uiView.tearDown()
    }
}

final class InlineStoryPlayerContainer: UIView {
    private var readyObservation: NSKeyValueObservation?
    private var observedPlayer: AVPlayer?
    private var didReportReady = false
    private var onReadyForDisplay: (() -> Void)?

    override class var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    // A raw video rendering surface, never itself interactive in either consumer
    // (inline story or floater/PIP) — both render separate SwiftUI content above it
    // for actual interaction. Set explicitly rather than relying on the SwiftUI
    // `.allowsHitTesting(false)` modifier callers apply: that modifier's propagation
    // across a `UIViewRepresentable` boundary proved unreliable elsewhere in this
    // hosting stack (see `floater_overlay_view.swift`'s `FloaterSessionView` — the
    // floater's own drag/tap gesture and its chrome buttons stopped receiving touches
    // wherever this view's real, UIKit-default-`true` `isUserInteractionEnabled` won
    // hit-testing priority over them instead).
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    func configure(
        player: AVPlayer,
        gravity: AVLayerVideoGravity,
        onReadyForDisplay: (() -> Void)?
    ) {
        self.onReadyForDisplay = onReadyForDisplay
        playerLayer.videoGravity = gravity
        guard observedPlayer !== player else {
            revealIfReady()
            return
        }
        readyObservation?.invalidate()
        observedPlayer = player
        didReportReady = false
        playerLayer.opacity = 0
        playerLayer.player = player
        readyObservation = playerLayer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.revealIfReady() }
        }
    }

    func tearDown() {
        readyObservation?.invalidate()
        readyObservation = nil
        observedPlayer = nil
        onReadyForDisplay = nil
        didReportReady = false
        playerLayer.opacity = 0
        playerLayer.player = nil
    }

    private func revealIfReady() {
        guard playerLayer.isReadyForDisplay else { return }
        playerLayer.opacity = 1
        guard !didReportReady else { return }
        didReportReady = true
        onReadyForDisplay?()
    }
}
