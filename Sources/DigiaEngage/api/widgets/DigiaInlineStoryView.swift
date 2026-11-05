import AVFoundation
import SwiftUI
import UIKit

// The inline story's entry points (T8): the rail in the slot and the full-screen viewer it opens.
// Both are thin wrappers over the one `story/` package (`StoryRail`, `StoryViewer`); what stays
// here is the inline campaign's own analytics, chrome and presentation, as on `main`.

@MainActor
struct DigiaInlineStoryView: View {
    let config: InlineStoryConfig
    let payload: CEPTriggerPayload

    @ObservedObject private var overlayController = SDKInstance.shared.controller

    init(config: InlineStoryConfig, payload: CEPTriggerPayload) {
        self.config = config
        self.payload = payload
    }

    var body: some View {
        if let image = config.previewImage {
            SingleImageStoryPreview(image: image) { openStory(at: 0, handover: nil) }
                .environment(\.digiaCampaignKey, payload.campaignKey)
        } else {
            rail
        }
    }

    private func openStory(at index: Int, handover: StoryHandover?) {
        SDKInstance.shared.reportStoryOpened(payload)
        SDKInstance.shared.reportClassicStoryOpened(payload, index: index)
        SDKInstance.shared.controller.showStoryOverlay(
            config: config,
            initialIndex: index,
            payload: payload,
            handover: handover
        )
    }

    private var rail: some View {
        StoryRail(
            items: config.items,
            mode: config.thumbnailVideoPlayback,
            cardWidth: CGFloat(config.card.width),
            cardHeight: CGFloat(config.card.height),
            cardCornerRadius: CGFloat(config.card.borderRadius),
            cardSpacing: CGFloat(config.card.spacing),
            overlayOpen: overlayController.activeStoryOverlay != nil
        ) { openStory(at: $0, handover: $1) }
        .environment(\.digiaCampaignKey, payload.campaignKey)
    }
}


@MainActor
private struct SingleImageStoryPreview: View {
    let image: StoryPreviewImageConfig
    let onTap: () -> Void

    var body: some View {
        let media = Color.black
            .overlay(StoryRemoteImage(urlString: image.url, fit: image.boxFit))
            .clipShape(RoundedRectangle(cornerRadius: CGFloat(image.cornerRadius), style: .continuous))
        Group {
            if image.aspectRatio > 0 {
                media.aspectRatio(CGFloat(image.aspectRatio), contentMode: .fit)
            } else {
                media.frame(height: CGFloat(image.height))
            }
        }
        .padding(EdgeInsets(
            top: image.padding.top, leading: image.padding.left,
            bottom: image.padding.bottom, trailing: image.padding.right
        ))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}


// MARK: - Dedicated story presenter

/// Presents the full-screen inline story as a modal `.overFullScreen`
/// `UIHostingController` on the app's top-most view controller.
///
/// We deliberately do NOT spin up a separate `UIWindow` here. A raw secondary
/// window works in a UIKit / React-Native host, but in a SwiftUI
/// `App`/`WindowGroup` host it renders its first frame and then stays inert:
/// SwiftUI never drives its update loop (frozen progress bar) and it never
/// joins the active responder chain (dead tap zones, swipe-dismiss and CTA).
/// A modal presentation is live and interactive in BOTH lifecycles. Being a
/// UIKit modal layered above any React-Native Fabric surface, it still owns
/// its touches outright — without competing with Fabric's
/// `RCTSurfaceTouchHandler` — mirroring the isolation Android gets from
/// presenting the story as a `Dialog`.
@MainActor
final class DigiaStoryPresenter {
    static let shared = DigiaStoryPresenter()

    /// The currently-presented story controller. Weak because UIKit retains a
    /// presented controller for us; we only need it to drive dismissal.
    private weak var presented: UIViewController?

    private init() {}

    func present(state: InlineStoryOverlayState) {
        // Replace any story already showing (e.g. tapping another story).
        // Tear the old one down without animation so it doesn't collide with
        // the incoming present.
        if let presented {
            self.presented = nil
            presented.presentingViewController?.dismiss(animated: false)
        }

        guard let presenter = ViewControllerUtil.topViewController() else { return }

        let host = DigiaStoryHostingController(
            rootView: InlineStoryOverlayContent(state: state)
                .environment(\.digiaCampaignKey, state.payload.campaignKey)
        )
        // Opaque black so the full-bleed media has no seam during the fade.
        host.view.backgroundColor = .black
        host.modalPresentationStyle = .overFullScreen
        host.modalTransitionStyle = .crossDissolve
        presented = host
        presenter.present(host, animated: true)
    }

    func dismiss() {
        guard let presented else { return }
        self.presented = nil
        presented.presentingViewController?.dismiss(animated: true)
    }
}

private final class DigiaStoryHostingController<Content: View>: UIHostingController<Content> {
    // The interactive "back" (left-edge swipe) and swipe-down dismissals are
    // handled inside the SwiftUI DragGesture in InlineStoryOverlayContent, not
    // by a UIKit gesture recognizer here — a separate UIScreenEdgePanGesture on
    // this view would be starved by SwiftUI's own pan recognizer. This
    // controller only adds hardware-keyboard ESC dismissal (e.g. simulator).
    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(dismissStoryOverlay)
            )
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func dismissStoryOverlay() {
        SDKInstance.shared.controller.dismissStoryOverlay()
    }
}

/// The inline campaign's analytics for the shared viewer: the classic story events, as on `main`.
@MainActor
private struct InlineStoryReporter: StoryViewerReporter {
    let payload: CEPTriggerPayload

    func onCompleted(total: Int, timeToCompleteMs: Int64) {
        SDKInstance.shared.reportStoryCompleted(payload, itemTotal: total, timeToCompleteMs: timeToCompleteMs)
    }

    func onDismissed(index: Int) {
        SDKInstance.shared.reportStoryStepDismissed(payload, itemIndex: index + 1)
    }
}

/// The inline story viewer: the shared `StoryViewer` with the inline chrome (progress strip, mute
/// and close buttons, the item's call to action), 88 pt edge strips to navigate, and the swipe
/// down / edge swipe to close, as on `main`.
@MainActor
private struct InlineStoryOverlayContent: View {
    let state: InlineStoryOverlayState

    private var variables: VariableContext {
        buildVariableContext(schemas: state.config.variableSchemas, cepVars: state.payload.variables)
    }

    var body: some View {
        let payload = state.payload
        let total = state.config.items.count
        StoryViewer(entry: StoryViewerEntry(
            stories: state.config.items,
            startIndex: state.initialIndex,
            handover: state.handover,
            restartOnCompleted: state.config.restartOnCompleted,
            startMuted: state.config.startMuted,
            defaultDurationMs: state.config.defaultDuration,
            reporter: InlineStoryReporter(payload: payload),
            onDismiss: { SDKInstance.shared.controller.dismissStoryOverlay() },
            // Step Viewed fires for each frame that becomes visible, the first included.
            onPageShown: { index in
                SDKInstance.shared.reportStoryStepViewed(payload, itemIndex: index + 1, itemTotal: total)
            },
            tapLayout: .edges(width: 88),
            reportsCompletionOnLoop: false,
            // Any teardown before the last frame is a dismissal (swipe, edge, ESC, close, CTA).
            dismissesOnDisappear: true
        )) { context in
            chrome(context)
        }
        .contentShape(Rectangle())
        // Dismissal gestures live in a single SwiftUI DragGesture so they don't fight a separate
        // UIKit recognizer (which SwiftUI's own pan would starve). Two "back" affordances:
        //   • swipe DOWN  — standard full-screen-cover dismissal
        //   • swipe RIGHT from the left edge — iOS interactive "back"
        // `simultaneousGesture`, so the edge taps beneath keep working.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    let dy = value.translation.height
                    let dx = value.translation.width
                    let predictedDX = value.predictedEndTranslation.width
                    let swipeDown = dy > 48 && dy > abs(dx)
                    let edgeBack =
                        value.startLocation.x < 40
                        && dx > abs(dy)
                        && (dx > 80 || predictedDX > 200)
                    if swipeDown || edgeBack {
                        SDKInstance.shared.controller.dismissStoryOverlay()
                    }
                }
        )
    }

    @ViewBuilder
    private func chrome(_ context: StoryViewerContext) -> some View {
        let item = context.item
        let indicator = state.config.indicator
        ZStack {
            VStack(spacing: 0) {
                StoryProgressBar(
                    totalItems: context.count,
                    currentIndex: context.index,
                    progress: context.progress,
                    config: indicator
                )
                // The viewer ignores the safe area for full-bleed media, so the real device
                // insets come from the window (see `safeAreaInsets`).
                .padding(.top, CGFloat(indicator.topPadding) + safeAreaInsets.top)
                .padding(.horizontal, CGFloat(indicator.horizontalPadding))

                Spacer(minLength: 0)

                if item.ctaEnabled, let text = item.ctaText, !text.isEmpty {
                    StoryCTAButton(item: item, variables: variables) {
                        handleCTA(item, index: context.index)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, safeAreaInsets.bottom + 20)
                }
            }

            VStack(spacing: 0) {
                StoryChrome(
                    closeButton: state.config.closeButton,
                    muteButton: state.config.muteButton,
                    showMute: item.type == .video,
                    muted: context.muted,
                    onClose: { SDKInstance.shared.controller.dismissStoryOverlay() },
                    onToggleMute: context.toggleMute
                )
                .padding(
                    .top,
                    safeAreaInsets.top + CGFloat(indicator.topPadding) + CGFloat(indicator.height) + 12
                )
                .padding(.trailing, CGFloat(indicator.horizontalPadding))

                Spacer(minLength: 0)
            }
        }
    }

    /// Real device safe-area insets, read from the active window.
    private var safeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .map(\.safeAreaInsets)
            .first(where: { $0.top > 0 }) ?? .zero
    }

    private func handleCTA(_ item: StoryItemConfig, index: Int) {
        let actions = item.actions
        let reportedAction = actions.first?.resolved(with: variables)
        let label = item.ctaText.map { interpolate($0, context: variables) }
        SDKInstance.shared.reportStoryStepClicked(
            state.payload,
            itemIndex: index + 1,
            ctaLabel: label,
            actionType: reportedAction?.analyticsType,
            actionUrl: reportedAction?.analyticsURL
        )
        Task {
            await SDKInstance.shared.executeActionFlow(
                actions,
                variables: variables,
                campaignKey: state.payload.campaignKey,
                localActionExecutor: LocalActionExecutor(
                    dismiss: { SDKInstance.shared.controller.dismissStoryOverlay() }
                )
            )
        }
    }
}


/// A story's still media, sized the way a story sizes it.
///
/// Not private: the canvas story draws the same stills, on its rail cards and
/// behind its full-screen pages. Its own version used a bare
/// `.aspectRatio(contentMode: .fill)`, which reports an ideal size larger than
/// the box it was given — enough to grow the enclosing stack and push the
/// story's chrome off the top of the screen.
@MainActor
struct StoryRemoteImage: View {
    let urlString: String
    let fit: StoryMediaFit

    @ViewBuilder
    var body: some View {
        if let url = URL(string: urlString) {
            let image = DigiaCachedImageView(
                url: url,
                placeholder: AnyView(Color(red: 0.10, green: 0.10, blue: 0.10))
            )
            if fit.stretchesImage {
                image.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                image.aspectRatio(contentMode: fit.imageContentMode)
            }
        } else {
            Color(red: 0.16, green: 0.16, blue: 0.16)
        }
    }
}


extension StoryMediaFit {
    var stretchesImage: Bool { self == .fill }

    var imageContentMode: ContentMode { self == .contain ? .fit : .fill }

    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .cover: .resizeAspectFill
        case .contain: .resizeAspect
        case .fill: .resize
        }
    }
}


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


private struct StoryCTAButton: View {
    let item: StoryItemConfig
    let variables: VariableContext
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(interpolate(item.ctaText ?? "", context: variables))
                .font(
                    Font(SDKInstance.shared.font.resolve(
                        size: 16,
                        weight: item.ctaFontWeight,
                        italic: false
                    ))
                )
                .foregroundColor(Color(hex: item.ctaTextColor) ?? .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .background(Color(hex: item.ctaBackgroundColor) ?? Color(hex: "#4945FF") ?? .blue)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(item.ctaCornerRadius), style: .continuous))
    }
}
