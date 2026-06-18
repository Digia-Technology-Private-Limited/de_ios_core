import SwiftUI
import SDWebImageSwiftUI
import Lottie
import AVKit
import UIKit

// MARK: - Root column

struct NudgeColumnContent: View {
    let column: NudgeColumn
    let onDismiss: () -> Void

    var body: some View {
        VStack(
            alignment: column.crossAxisAlignment.horizontalAlignment,
            spacing: column.mainAxisAlignment == .start ? column.spacing : 0
        ) {
            ForEach(Array(column.children.enumerated()), id: \.offset) { _, node in
                NudgeNodeView(node: node, onDismiss: onDismiss)
                    .frame(
                        maxWidth: node.box.fillWidth ? .infinity : nil,
                        alignment: node.box.selfAlign.flatMap { $0.alignment } ?? .leading
                    )
            }
        }
        .frame(
            maxWidth: column.children.contains(where: { $0.box.fillWidth }) ? .infinity : nil,
            alignment: column.crossAxisAlignment.frameAlignment
        )
    }
}

// MARK: - Per-node dispatch

private struct NudgeNodeView: View {
    let node: NudgeNode
    let onDismiss: () -> Void

    var body: some View {
        Group {
            switch node {
            case .text(let n):     NudgeTextView(node: n)
            case .image(let n):    NudgeImageView(node: n)
            case .button(let n):   NudgeButtonView(node: n, onDismiss: onDismiss)
            case .gap(let n):      Spacer().frame(height: n.height)
            case .divider(let n):  NudgeDividerView(node: n)
            case .lottie(let n):   NudgeLottieView(node: n)
            case .carousel(let n): NudgeCarouselView(node: n)
            case .video(let n):    NudgeVideoView(node: n)
            }
        }
        .nudgeBox(node.box)
    }
}

// MARK: - Text

private struct NudgeTextView: View {
    let node: NudgeText
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        Text(interpolate(node.text, variables: variables))
            .font(SDKInstance.shared.fontFactory.getDefaultFont(
                size: Double(node.fontSize), weight: node.fontWeight, italic: false
            ))
            .fontWeight(node.fontWeight)
            .foregroundStyle(node.color)
            .multilineTextAlignment(node.textAlignment)
            .frame(maxWidth: node.box.fillWidth ? .infinity : nil,
                   alignment: node.textAlignment.frameAlignment)
    }
}

// MARK: - Image

private struct NudgeImageView: View {
    let node: NudgeImage
    @Environment(\.digiaVariables) private var variables

    private var url: String { interpolate(node.url, variables: variables) }

    var body: some View {
        if url.isEmpty {
            nudgePlaceholder(label: "Image", height: node.box.fixedHeight ?? 120)
        } else if node.aspectRatio > 0 {
            WebImage(url: URL(string: url))
                .resizable()
                .aspectRatio(node.aspectRatio, contentMode: node.contentMode)
                .frame(maxWidth: node.box.fillWidth ? .infinity : nil)
        } else {
            WebImage(url: URL(string: url))
                .resizable()
                .aspectRatio(contentMode: node.contentMode)
                .frame(
                    maxWidth: node.box.fillWidth ? .infinity : nil,
                    maxHeight: node.box.fixedHeight
                )
                .clipped()
        }
    }
}

// MARK: - Button

private struct NudgeButtonView: View {
    let node: NudgeButton
    let onDismiss: () -> Void
    @Environment(\.digiaVariables) private var variables

    private var filled: Bool { node.variant == .fill || node.variant == .elevated }

    var body: some View {
        Button(action: handleTap) {
            Text(interpolate(node.label, variables: variables))
                .font(SDKInstance.shared.fontFactory.getDefaultFont(
                    size: Double(node.fontSize), weight: node.fontWeight, italic: false
                ))
                .fontWeight(node.fontWeight)
                .foregroundStyle(filled ? node.textColor : node.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: node.box.fillWidth ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: node.box.fillWidth ? .infinity : nil)
        .background(filled ? node.background : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: node.radius))
        .shadow(radius: node.variant == .elevated ? 3 : 0)
        .overlay(
            node.variant == .outline
                ? RoundedRectangle(cornerRadius: node.radius)
                    .stroke(node.background, lineWidth: 1.5)
                : nil
        )
    }

    private func handleTap() {
        // A primary-button click is a Digia-only engagement signal (matches
        // Android's NudgeNodeRenderer) — it is not forwarded to the CEP plugin.
        if node.isPrimary {
            let action = node.actions.first
            SDKInstance.shared.emitNudgeClick(
                elementId: "cta_primary",
                ctaLabel: node.label,
                actionType: Self.actionType(for: action),
                actionUrl: Self.actionUrl(for: action),
                ctaRole: "primary"
            )
        }
        for action in node.actions {
            switch action {
            case .dismiss:
                onDismiss()
            case .openUrl(let url), .openDeeplink(let url):
                // Consult the CEP plugin first; only fall back to a native open
                // when no plugin handled the action (mirrors Android).
                let payload = SDKInstance.shared.controller.activeNudge?.payload
                let handled = payload.flatMap {
                    SDKInstance.shared.controller.onAction?("deep_link", url, $0)
                } ?? false
                if !handled, let u = URL(string: url) {
                    UIApplication.shared.open(u)
                }
            case .copyToClipboard(let text):
                UIPasteboard.general.string = interpolate(text, variables: variables)
            case .share(let text):
                let activity = UIActivityViewController(
                    activityItems: [interpolate(text, variables: variables)],
                    applicationActivities: nil
                )
                ViewControllerUtil.present(activity)
            }
        }
    }

    private static func actionType(for action: NudgeAction?) -> String? {
        switch action {
        case .openUrl: return "url"
        case .openDeeplink: return "deeplink"
        case .dismiss: return "dismiss"
        case .copyToClipboard, .share: return "custom"
        case nil: return nil
        }
    }

    private static func actionUrl(for action: NudgeAction?) -> String? {
        switch action {
        case .openUrl(let url), .openDeeplink(let url): return url
        default: return nil
        }
    }
}

// MARK: - Divider

private struct NudgeDividerView: View {
    let node: NudgeDivider

    var body: some View {
        HStack(spacing: 0) {
            if node.indent > 0 { Spacer().frame(width: node.indent) }
            Rectangle()
                .fill(node.color)
                .frame(height: node.thickness)
            if node.endIndent > 0 { Spacer().frame(width: node.endIndent) }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Lottie

private struct NudgeLottieView: View {
    let node: NudgeLottie
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        let resolved = interpolate(node.url, variables: variables)
        if resolved.isEmpty {
            nudgePlaceholder(label: "Lottie", height: node.height)
        } else if let url = URL(string: resolved) {
            Group {
                if node.autoplay {
                    LottieView {
                        await LottieAnimation.loadedFrom(url: url)
                    }
                    .playing(loopMode: node.loop ? .loop : .playOnce)
                } else {
                    LottieView {
                        await LottieAnimation.loadedFrom(url: url)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: node.height)
        }
    }
}

// MARK: - Carousel

private struct NudgeCarouselView: View {
    let node: NudgeCarousel
    @Environment(\.digiaVariables) private var variables
    @State private var currentIndex = 0
    @State private var autoPlayTimer: Timer? = nil

    private var images: [String] {
        node.images.map { interpolate($0, variables: variables) }.filter { !$0.isEmpty }
    }
    private var pageCount: Int { node.loop ? 9999 : images.count }

    var body: some View {
        let images = self.images
        if images.isEmpty {
            nudgePlaceholder(label: "Image", height: node.height)
        } else {
            VStack(spacing: 0) {
                TabView(selection: $currentIndex) {
                    ForEach(0 ..< pageCount, id: \.self) { index in
                        WebImage(url: URL(string: images[index % images.count]))
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity)
                            .frame(height: node.height)
                            .clipped()
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: node.height)
                .onAppear {
                    guard node.autoPlay, images.count > 1 else { return }
                    let interval = TimeInterval(node.autoPlayIntervalMs) / 1000
                    autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                        DispatchQueue.main.async {
                            withAnimation { currentIndex += 1 }
                        }
                    }
                }
                .onDisappear {
                    autoPlayTimer?.invalidate()
                    autoPlayTimer = nil
                }

                if node.showIndicator && images.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0 ..< images.count, id: \.self) { i in
                            let isActive = (currentIndex % images.count) == i
                            Circle()
                                .fill(isActive ? Color(hex: "#4945FF") ?? .blue
                                               : Color(hex: "#CBD5E1") ?? .gray)
                                .frame(width: isActive ? 8 : 6, height: isActive ? 8 : 6)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - Video

private struct NudgeVideoView: View {
    let node: NudgeVideo
    @Environment(\.digiaVariables) private var variables
    @State private var player: AVPlayer? = nil

    private var url: String { interpolate(node.url, variables: variables) }

    var body: some View {
        Group {
            if url.isEmpty {
                nudgePlaceholder(label: "Video", height: node.height)
            } else if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: node.height)
            } else {
                Color.black
                    .frame(maxWidth: .infinity)
                    .frame(height: node.height)
            }
        }
        .onAppear {
            guard !url.isEmpty, let url = URL(string: url) else { return }
            let p = AVPlayer(url: url)
            p.isMuted = node.muted
            if node.autoplay { p.play() }
            player = p
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }
}

// MARK: - Placeholder

private func nudgePlaceholder(label: String, height: CGFloat) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(hex: "#F1F1F5") ?? Color(.systemGray6))
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(Color(hex: "#9A9AAD") ?? .secondary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: height)
}

// MARK: - Modifier

private extension View {
    @ViewBuilder
    func nudgeBox(_ box: NudgeBox) -> some View {
        self
            .padding(EdgeInsets(
                top: box.paddingTop, leading: box.paddingLeft,
                bottom: box.paddingBottom, trailing: box.paddingRight
            ))
            .frame(maxWidth: box.fillWidth ? .infinity : nil)
            .frame(
                width: box.fixedWidth,
                height: box.fixedHeight
            )
            .background(
                box.background.map { bg in
                    AnyView(RoundedRectangle(cornerRadius: box.borderRadius).fill(bg))
                } ?? AnyView(EmptyView())
            )
            .clipShapeIfRadius(cornerRadius: box.borderRadius)
            .overlay(
                (box.borderColor != nil && box.borderWidth > 0)
                    ? AnyView(RoundedRectangle(cornerRadius: box.borderRadius)
                        .stroke(box.borderColor!, lineWidth: box.borderWidth))
                    : AnyView(EmptyView())
            )
            .padding(EdgeInsets(
                top: box.marginTop, leading: box.marginLeft,
                bottom: box.marginBottom, trailing: box.marginRight
            ))
    }
}

// MARK: - Conditional clip helper

private extension View {
    @ViewBuilder
    func clipShapeIfRadius(cornerRadius: CGFloat) -> some View {
        if cornerRadius > 0 {
            clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}

// MARK: - Alignment helpers

private extension NudgeCrossAxisAlignment {
    var horizontalAlignment: HorizontalAlignment {
        switch self { case .start: return .leading; case .center: return .center; case .end: return .trailing }
    }

    var frameAlignment: Alignment {
        switch self { case .start: return .leading; case .center: return .center; case .end: return .trailing }
    }
}

private extension NudgeSelfAlign {
    var alignment: Alignment {
        switch self { case .start: return .leading; case .center: return .center; case .end: return .trailing }
    }
}

private extension TextAlignment {
    var frameAlignment: Alignment {
        switch self { case .leading: return .leading; case .center: return .center; case .trailing: return .trailing }
    }
}
