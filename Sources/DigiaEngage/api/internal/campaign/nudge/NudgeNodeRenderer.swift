import AVKit
@_implementationOnly import Lottie
@_implementationOnly import SDWebImageSwiftUI
import SwiftUI
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
                        maxWidth: (node.box.fillWidth || node.box.selfAlign != nil)
                            ? .infinity : nil,
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
            case .text(let n): NudgeTextView(node: n)
            case .image(let n): NudgeImageView(node: n)
            case .button(let n): NudgeButtonView(node: n, onDismiss: onDismiss)
            case .gap(let n): Spacer().frame(height: n.height)
            case .divider(let n): NudgeDividerView(node: n)
            case .lottie(let n): NudgeLottieView(node: n)
            case .carousel(let n): NudgeCarouselView(node: n)
            case .video(let n): NudgeVideoView(node: n)
            }
        }
        .nudgeBox(node.box)
    }
}

// MARK: - Text

private struct NudgeTextView: View {
    let node: NudgeText
    @Environment(\.digiaVariables) private var variables

    // Rendered via a TextKit-1 UITextView so it can carry per-run decoration
    // colour/thickness and a block-level line height (paragraph style) — neither
    // of which SwiftUI `Text` can express.
    var body: some View {
        NudgeRichText(attributed: attributed, fillWidth: node.box.fillWidth)
            .frame(
                maxWidth: node.box.fillWidth ? .infinity : nil,
                alignment: node.textAlignment.frameAlignment)
    }

    private var attributed: NSAttributedString {
        let result = NSMutableAttributedString()
        // One run for plain text; otherwise the styled spans (each over the base).
        let runs: [(String, NudgeSpanStyle?)] =
            node.spans.isEmpty
            ? [(interpolate(node.text, context: variables), nil)]
            : node.spans.map { (interpolate($0.text, context: variables), $0.style) }
        for (text, style) in runs {
            result.append(NSAttributedString(string: text, attributes: runAttributes(style)))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsAlignment
        // Match Android/Compose (`lineHeight.em`): pin the line height to base font
        // size × multiplier. Use only `minimumLineHeight` — NOT `maximumLineHeight`
        // (which clips glyphs taller than the line, e.g. a big "lo") and NOT
        // `lineHeightMultiple` (which scales the line's *natural* height, ballooning
        // lines that contain a much larger span). A span taller than the line then
        // grows that one line instead of clipping.
        if let lineHeight = node.lineHeight {
            paragraph.minimumLineHeight = node.fontSize * lineHeight
        }
        result.addAttribute(
            .paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length)
        )
        return result
    }

    private func runAttributes(_ style: NudgeSpanStyle?) -> [NSAttributedString.Key: Any] {
        let font = SDKInstance.shared.fontFactory.getDefaultUIFont(
            size: Double(style?.fontSize ?? node.fontSize),
            weight: style?.fontWeight ?? node.fontWeight,
            italic: style?.italic ?? false
        )
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(style?.color ?? node.color),
        ]
        if let highlight = style?.highlightColor { attrs[.backgroundColor] = UIColor(highlight) }
        if style?.underline == true { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if style?.strikethrough == true {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        // Colour is drawn natively by UIKit at the correct position via underlineColor /
        // strikethroughColor; we only take over the drawing when a custom thickness is
        // set (see DigiaDecorationLayoutManager), reusing digiaDecorationColor for it.
        if let color = style?.decorationColor {
            let uiColor = UIColor(color)
            attrs[.underlineColor] = uiColor
            attrs[.strikethroughColor] = uiColor
            attrs[.digiaDecorationColor] = uiColor
        }
        if let thickness = style?.decorationThickness {
            attrs[.digiaDecorationThickness] = thickness
        }
        return attrs
    }

    private var nsAlignment: NSTextAlignment {
        switch node.textAlignment {
        case .center: return .center
        case .trailing: return .right
        default: return .left
        }
    }
}

// MARK: - Image

private struct NudgeImageView: View {
    let node: NudgeImage
    @Environment(\.digiaVariables) private var variables

    private var url: String { interpolate(node.url, context: variables) }
    private var maxWidth: CGFloat? { node.box.fillWidth ? .infinity : nil }
    private var image: some View { WebImage(url: URL(string: url)).resizable() }

    var body: some View {
        content

            .clipShapeIfRadius(cornerRadius: max(0, node.box.borderRadius - node.box.borderWidth))
    }

    @ViewBuilder
    private var content: some View {
        if url.isEmpty {
            nudgePlaceholder(label: "Image", height: node.box.fixedHeight ?? 120)
        } else if node.aspectRatio > 0 {
            aspectRatioImage
        } else {
            fixedImage
        }
    }

    // Aspect ratio drives the frame's width:height; the image is scaled to that frame
    // per the fit.
    @ViewBuilder
    private var aspectRatioImage: some View {
        switch node.fit {
        case .contain:
            image.aspectRatio(node.aspectRatio, contentMode: .fit)
                .frame(maxWidth: maxWidth)
        case .cover:
            image.aspectRatio(node.aspectRatio, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()
        case .fill:
            // Stretch: a clear box of the target ratio, image overlaid to fill it exactly.
            Color.clear
                .aspectRatio(node.aspectRatio, contentMode: .fit)
                .overlay(image)
                .frame(maxWidth: .infinity)
                .clipped()
        }
    }

    // No aspect ratio: frame is fillWidth × fixedHeight; the image is scaled to it per fit.
    @ViewBuilder
    private var fixedImage: some View {
        switch node.fit {
        case .contain:
            image.scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: node.box.fixedHeight)
        case .cover:
            // scaledToFill overflows horizontally with an unbounded (hug) width,
            // pushing the rounded corners off-screen so the radius looks unapplied.
            // Cover always fills the available width, so bound it to the parent.
            image.scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: node.box.fixedHeight)
                .clipped()
        case .fill:
            // No scaledTo: the image stretches to exactly fill the frame bounds.
            image
                .frame(maxWidth: .infinity, maxHeight: node.box.fixedHeight)
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
            Text(interpolate(node.label, context: variables))
                .font(
                    SDKInstance.shared.fontFactory.getDefaultFont(
                        size: Double(node.fontSize), weight: node.fontWeight, italic: false
                    )
                )
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
                let handled =
                    payload.flatMap {
                        SDKInstance.shared.controller.onAction?("deep_link", url, $0)
                    } ?? false
                if !handled, let u = URL(string: url) {
                    UIApplication.shared.open(u)
                }
            case .copyToClipboard(let text):
                UIPasteboard.general.string = interpolate(text, context: variables)
            case .share(let text):
                let activity = UIActivityViewController(
                    activityItems: [interpolate(text, context: variables)],
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
        let resolved = interpolate(node.url, context: variables)
        if resolved.isEmpty {
            nudgePlaceholder(label: "Lottie", height: node.height)
        } else if let url = URL(string: resolved) {
            Group {
                if node.autoplay {
                    lottie(url: url)
                        .playing(loopMode: node.loop ? .loop : .playOnce)
                } else {
                    lottie(url: url)
                }
            }
            .nudgeMediaFrame(aspectRatio: node.aspectRatio, height: node.height)
        }
    }

    // `.resizable()` lets the animation fill the frame; `contentMode` then applies the fit.
    private func lottie(url: URL) -> LottieView<EmptyView> {
        LottieView { await LottieAnimation.loadedFrom(url: url) }
            .resizable()
            .configure(\.contentMode, to: node.fit.uiContentMode)
    }
}

// MARK: - Carousel

private struct NudgeCarouselView: View {
    let node: NudgeCarousel
    @Environment(\.digiaVariables) private var variables
    @State private var currentIndex = 0
    @State private var autoPlayTimer: Timer? = nil

    private var images: [String] {
        node.images.map { interpolate($0, context: variables) }.filter { !$0.isEmpty }
    }
    private var pageCount: Int { node.loop ? 9999 : images.count }

    var body: some View {
        let images = self.images
        if images.isEmpty {
            nudgePlaceholder(label: "Image", height: node.height)
        } else {
            VStack(spacing: 0) {
                TabView(selection: $currentIndex) {
                    ForEach(0..<pageCount, id: \.self) { index in
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
                    autoPlayTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true)
                    { _ in
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
                        ForEach(0..<images.count, id: \.self) { i in
                            let isActive = (currentIndex % images.count) == i
                            Circle()
                                .fill(
                                    isActive
                                        ? Color(hex: "#4945FF") ?? .blue
                                        : Color(hex: "#CBD5E1") ?? .gray
                                )
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

    private var url: String { interpolate(node.url, context: variables) }

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

extension View {
    @ViewBuilder
    fileprivate func nudgeBox(_ box: NudgeBox) -> some View {
        self
            .padding(
                EdgeInsets(
                    top: box.paddingTop, leading: box.paddingLeft,
                    bottom: box.paddingBottom, trailing: box.paddingRight
                )
            )
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
                    ? AnyView(
                        RoundedRectangle(cornerRadius: box.borderRadius)
                            .stroke(box.borderColor!, lineWidth: box.borderWidth))
                    : AnyView(EmptyView())
            )
            .padding(
                EdgeInsets(
                    top: box.marginTop, leading: box.marginLeft,
                    bottom: box.marginBottom, trailing: box.marginRight
                ))
    }
}

// MARK: - Conditional clip helper

extension View {
    @ViewBuilder
    fileprivate func clipShapeIfRadius(cornerRadius: CGFloat) -> some View {
        if cornerRadius > 0 {
            clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self
        }
    }
}

// MARK: - Media (image / Lottie) helpers

extension NudgeContentFit {
    /// Lottie scales via its underlying `LottieAnimationView` (a UIView), so each fit
    /// maps to a UIView content mode.
    fileprivate var uiContentMode: UIView.ContentMode {
        switch self {
        case .cover: return .scaleAspectFill
        case .contain: return .scaleAspectFit
        case .fill: return .scaleToFill
        }
    }
}

extension View {
    /// Sizes a full-width media view: aspect ratio (when set) drives the height,
    /// otherwise a fixed height is used. Mirrors the image renderer's frame rule.
    @ViewBuilder
    fileprivate func nudgeMediaFrame(aspectRatio: CGFloat, height: CGFloat) -> some View {
        if aspectRatio > 0 {
            self.frame(maxWidth: .infinity)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .clipped()
        } else {
            self.frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
        }
    }
}

// MARK: - Alignment helpers

extension NudgeCrossAxisAlignment {
    fileprivate var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }

    fileprivate var frameAlignment: Alignment {
        switch self {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }
}

extension NudgeSelfAlign {
    fileprivate var alignment: Alignment {
        switch self {
        case .start: return .leading
        case .center: return .center
        case .end: return .trailing
        }
    }
}

extension TextAlignment {
    fileprivate var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
