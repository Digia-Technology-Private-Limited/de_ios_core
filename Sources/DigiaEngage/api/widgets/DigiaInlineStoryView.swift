import AVFoundation
import SwiftUI
import UIKit
internal import DigiaVideoEngine

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
/// and close buttons, the item's call to action), 88 pt edge strips to navigate, and the edge
/// swipe to close (swipe down is the shared viewer's), as on `main`.
@MainActor
struct InlineStoryOverlayContent: View {
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
            dismissesOnDisappear: true,
            // `main`'s inline story video page letterboxed on this dark grey (OD-18).
            videoGroundAfterFirstFrame: mediaVideoBackdrop
        )) { context in
            chrome(context)
        }
        .contentShape(Rectangle())
        // Swipe down is the shared viewer's own (every story has it). The inline story adds the
        // iOS interactive "back": a swipe right from the left edge. `simultaneousGesture`, so the
        // edge taps beneath keep working.
        .simultaneousGesture(
            DragGesture(minimumDistance: 10)
                .onEnded { value in
                    let dy = value.translation.height
                    let dx = value.translation.width
                    let predictedDX = value.predictedEndTranslation.width
                    let edgeBack =
                        value.startLocation.x < 40
                        && dx > abs(dy)
                        && (dx > 80 || predictedDX > 200)
                    if edgeBack {
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
