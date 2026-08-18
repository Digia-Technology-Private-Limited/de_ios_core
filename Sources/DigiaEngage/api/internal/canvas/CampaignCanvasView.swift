@_implementationOnly import SDWebImageSwiftUI
import AVFoundation
import AVKit
@_implementationOnly import Lottie
import SwiftUI
import UIKit

private let maxFloatingCanvasUpscale: CGFloat = 1.15
private let canvasTextSpanElementID = "canvas_text_span"

struct CampaignCanvasView: View {
    let canvas: CampaignCanvas
    let surface: NudgeSurface
    let designWidth: CGFloat
    var runtimeViewportWidth: CGFloat? = nil
    let availableSize: CGSize
    let onAction: (CampaignCanvasActionRequest) -> Void
    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    private var designScale: CGFloat {
        let base = (runtimeViewportWidth ?? availableSize.width) / max(designWidth, 1)
        return surface.isBottomSheet ? base : min(base, maxFloatingCanvasUpscale)
    }
    private var scale: CGFloat {
        let naturalWidth = max(canvas.width * designScale, 1)
        let naturalHeight = max(canvas.height * designScale, 1)
        return designScale * min(1, availableSize.width / naturalWidth, availableSize.height / naturalHeight)
    }

    var body: some View {
        CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: surface.cornerRadius / max(designScale, 0.001),
            isDark: theme.isDark(colorScheme),
            onAction: onAction
        )
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: canvas.width * scale, height: canvas.height * scale, alignment: .topLeading)
    }
}

private struct CampaignCanvasStage: View {
    let canvas: CampaignCanvas
    let authoredCornerRadius: CGFloat
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CampaignCanvasPaintView(paint: canvas.background, isDark: isDark)
            ForEach(canvas.children) { child in
                CanvasChildView(child: child, isDark: isDark, onAction: onAction)
                    .frame(width: child.rect.width, height: child.rect.height, alignment: .topLeading)
                    .modifier(CanvasChildBoundsModifier(clips: child.clipsToAuthoredRect))
                    .allowsHitTesting(child.isHitTestable)
                    .offset(x: child.rect.x, y: child.rect.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: max(0, authoredCornerRadius)))
    }
}

private struct CanvasChildView: View {
    let child: CampaignCanvasChild
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    var body: some View {
        switch child {
        case .widget(_, _, let widget): CampaignCanvasRendererRegistry.render(widget, isDark: isDark, onAction: onAction)
        case .tapRegion(let id, _, let actions):
            Color.clear.contentShape(Rectangle()).onTapGesture {
                onAction(CampaignCanvasActionRequest(actions: actions, elementId: id))
            }
        }
    }
}

@MainActor
enum CampaignCanvasRendererRegistry {
    typealias Renderer = (CampaignCanvasWidget, Bool, @escaping (CampaignCanvasActionRequest) -> Void) -> AnyView
    private static let renderers: [String: Renderer] = [
        "text": { widget, dark, action in guard case .text(let box, let block, let shadow) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasTextRenderer(box: box, block: block, shadow: shadow, isDark: dark, onAction: action)) },
        "image": { widget, dark, action in guard case .image(let box, let source, let fit, let x, let y, let scale, let tint) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasImageRenderer(box: box, source: source, fit: fit, positionX: x, positionY: y, scale: scale, tint: tint, isDark: dark)) },
        "button": { widget, dark, action in guard case .button(let box, let label, let radius, let style, let shadow, let primary, let destructive, let apply, let actions, let confirm) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasButtonRenderer(box: box, label: label, cornerRadius: radius, style: style, shadow: shadow, isPrimary: primary, isDestructive: destructive, applyDestructiveStyling: apply, actions: actions, confirm: confirm, isDark: dark, onAction: action)) },
        "progress": { widget, dark, _ in guard case .progress(let box, let mode, let percent, let start, let current, let end, let indicator, let track, let radius, let animation) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasProgressRenderer(box: box, valueMode: mode, percent: percent, rangeStart: start, rangeCurrent: current, rangeEnd: end, indicator: indicator, track: track, cornerRadius: radius, animateOnAppear: animation, isDark: dark)) },
        "lottie": { widget, dark, _ in guard case .lottie(let box, let source, let autoplay, let loop, let fit) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasLottieRenderer(box: box, source: source, autoplay: autoplay, loop: loop, fit: fit, isDark: dark)) },
        "video": { widget, dark, _ in guard case .video(let box, let source, let autoplay, let loop, let muted, let controls, let fit) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasVideoRenderer(box: box, source: source, autoplay: autoplay, loop: loop, muted: muted, showControls: controls, fit: fit, isDark: dark)) },
        "container": { widget, dark, _ in guard case .container(let fill, let radius, let border, let shadow) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasContainerRenderer(fill: fill, cornerRadius: radius, border: border, shadow: shadow, isDark: dark)) },
        "divider": { widget, dark, _ in guard case .divider(let box, let axis, let pattern, let cap, let inset, let dash, let color) = widget else { return AnyView(EmptyView()) }; return AnyView(CanvasDividerRenderer(box: box, axis: axis, pattern: pattern, strokeCap: cap, inset: inset, dashPattern: dash, color: color, isDark: dark)) },
    ]

    static func render(_ widget: CampaignCanvasWidget, isDark: Bool, onAction: @escaping (CampaignCanvasActionRequest) -> Void) -> AnyView {
        let key: String
        switch widget { case .text: key = "text"; case .image: key = "image"; case .button: key = "button"; case .progress: key = "progress"; case .lottie: key = "lottie"; case .video: key = "video"; case .container: key = "container"; case .divider: key = "divider" }
        guard let renderer = renderers[key] else { preconditionFailure("Missing Campaign Canvas renderer for \(key)") }
        return renderer(widget, isDark, onAction)
    }

    static func hasRenderer(for widget: CampaignCanvasWidget) -> Bool {
        let key: String
        switch widget { case .text: key = "text"; case .image: key = "image"; case .button: key = "button"; case .progress: key = "progress"; case .lottie: key = "lottie"; case .video: key = "video"; case .container: key = "container"; case .divider: key = "divider" }
        return renderers[key] != nil
    }
}

private struct CanvasTextRenderer: View {
    let box: CampaignCanvasBox; let block: CampaignCanvasTextBlock; let shadow: CampaignCanvasShadow?; let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark, clipsContent: false) {
            CampaignCanvasTextView(block: block, isDark: isDark, onAction: onAction, shadow: shadow)
        }
    }
}

private struct CampaignCanvasTextView: View {
    let block: CampaignCanvasTextBlock; let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    var colorOverride: UIColor? = nil
    var shadow: CampaignCanvasShadow? = nil
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        let content = attributed
        ZStack {
            if let shadow, shadow.blur > 0 || shadow.spread > 0 || shadow.offsetX != 0 || shadow.offsetY != 0 {
                CanvasRichText(
                    attributed: shadowAttributed(from: content, color: CampaignCanvasTheme.shared.color(shadow.color, isDark: isDark)),
                    fillWidth: block.sizingMode != "hug",
                    maxLines: block.overflow == "ellipsis" ? block.maxLines : 0,
                    overflow: block.overflow,
                    textAlignment: block.textAlign.uiTextAlignment,
                    onSpan: { _ in },
                    spans: []
                )
                .blur(radius: shadow.blur / 2 + shadow.spread)
                .offset(x: shadow.offsetX, y: shadow.offsetY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            CanvasRichText(
                attributed: content,
                fillWidth: block.sizingMode != "hug",
                maxLines: block.overflow == "ellipsis" ? block.maxLines : 0,
                overflow: block.overflow,
                textAlignment: block.textAlign.uiTextAlignment,
                onSpan: { span in onAction(CampaignCanvasActionRequest(actions: span.actions, elementId: canvasTextSpanElementID, label: span.text)) },
                spans: block.spans
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: block.alignment)
    }

    private func shadowAttributed(from attributed: NSAttributedString, color: Color) -> NSAttributedString {
        let value = NSMutableAttributedString(attributedString: attributed)
        let range = NSRange(location: 0, length: value.length)
        value.addAttribute(.foregroundColor, value: UIColor(color), range: range)
        [.backgroundColor, .link, .underlineStyle, .underlineColor, .strikethroughStyle,
         .strikethroughColor, .digiaDecorationColor, .digiaDecorationThickness].forEach {
            value.removeAttribute($0, range: range)
        }
        return value
    }

    private var attributed: NSAttributedString {
        let first = block.spans.first
        let baseTypography = first?.typography ?? CampaignTypography()
        let baseColor = colorOverride ?? first?.color.map { UIColor(CampaignCanvasTheme.shared.color($0, isDark: isDark)) } ?? .label
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = block.textAlign.uiTextAlignment
        if let lineHeight = baseTypography.lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        for (index, span) in block.spans.enumerated() {
            let typography = span.typography
            let color = colorOverride ?? span.color.map { UIColor(CampaignCanvasTheme.shared.color($0, isDark: isDark)) } ?? baseColor
            var attributes: [NSAttributedString.Key: Any] = [
                .font: SDKInstance.shared.font.resolve(
                    size: Double(typography?.fontSize ?? baseTypography.fontSize ?? 16),
                    weight: typography?.fontWeight ?? baseTypography.fontWeight ?? 400,
                    italic: span.italic,
                    fallbackFamily: typography?.fontFamily ?? baseTypography.fontFamily
                ),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if let spacing = typography?.letterSpacing ?? baseTypography.letterSpacing { attributes[.kern] = spacing }
            if let highlight = span.highlightColor { attributes[.backgroundColor] = UIColor(CampaignCanvasTheme.shared.color(highlight, isDark: isDark)) }
            switch span.decoration {
            case .underline: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .lineThrough: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .none: break
            }
            if let decorationColor = span.decorationColor {
                let value = UIColor(CampaignCanvasTheme.shared.color(decorationColor, isDark: isDark))
                attributes[span.decoration == .lineThrough ? .strikethroughColor : .underlineColor] = value
                attributes[.digiaDecorationColor] = value
            }
            if let thickness = span.decorationThickness { attributes[.digiaDecorationThickness] = thickness }
            if !span.actions.isEmpty { attributes[.link] = URL(string: "digia-canvas://span/\(index)")! }
            result.append(NSAttributedString(string: interpolate(span.text, context: variables), attributes: attributes))
        }
        return result
    }
}

private struct CanvasRichText: UIViewRepresentable {
    let attributed: NSAttributedString; let fillWidth: Bool; let maxLines: Int; let overflow: String
    let textAlignment: NSTextAlignment; let onSpan: (CampaignCanvasTextSpan) -> Void
    var spans: [CampaignCanvasTextSpan] = []

    final class Coordinator: NSObject, UITextViewDelegate {
        var spans: [CampaignCanvasTextSpan] = []; var onSpan: ((CampaignCanvasTextSpan) -> Void)?
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            guard URL.scheme == "digia-canvas", let index = Int(URL.lastPathComponent), spans.indices.contains(index) else { return false }
            onSpan?(spans[index]); return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage(); let manager = DigiaDecorationLayoutManager(); let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0; container.widthTracksTextView = true
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        let view = UITextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator; view.isEditable = false; view.isScrollEnabled = false
        view.backgroundColor = .clear; view.textContainerInset = .zero
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentHuggingPriority(fillWidth ? .defaultLow : .required, for: .horizontal)
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.spans = spans; context.coordinator.onSpan = onSpan
        view.textStorage.setAttributedString(attributed); view.textAlignment = textAlignment
        view.textContainer.maximumNumberOfLines = max(0, maxLines)
        view.textContainer.lineBreakMode = overflow == "ellipsis" ? .byTruncatingTail : .byClipping
        let hasActions = !spans.allSatisfy { $0.actions.isEmpty }
        view.isSelectable = hasActions
        view.isUserInteractionEnabled = hasActions
    }
    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        view.delegate = nil; view.isSelectable = false; coordinator.onSpan = nil; coordinator.spans = []
    }
    @available(iOS 16, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fit = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: fillWidth ? width : ceil(fit.width), height: ceil(fit.height))
    }
}

private struct CanvasImageRenderer: View {
    let box: CampaignCanvasBox; let source: CampaignCanvasMediaSource; let fit: String
    let positionX: CGFloat; let positionY: CGFloat; let scale: CGFloat; let tint: CampaignColor?; let isDark: Bool
    var body: some View { CampaignCanvasBoxView(box: box, isDark: isDark) { FocalCanvasImage(source: source, isDark: isDark, fit: fit, x: positionX, y: positionY, scale: scale, tint: tint, failureLabel: "Image") } }
}

private struct CanvasButtonRenderer: View {
    let box: CampaignCanvasBox; let label: CampaignCanvasTextBlock; let cornerRadius: CampaignCanvasCornerRadius
    let style: CampaignCanvasButtonStyle; let shadow: CampaignCanvasShadow?
    let isPrimary: Bool; let isDestructive: Bool; let applyDestructiveStyling: Bool
    let actions: [EngageAction]; let confirm: CampaignCanvasConfirmDialog; let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    @State private var confirming = false
    private let danger = CampaignColor.literal("#FFD92D20")
    var body: some View {
        ZStack {
            if let shadow { CampaignCanvasShadowView(shadow: shadow, cornerRadius: cornerRadius, isDark: isDark, outsideOnly: true) }
            CampaignCanvasBoxView(box: box, isDark: isDark) {
                Group {
                    if actions.isEmpty {
                        buttonContent
                    } else {
                        Button { if isDestructive { confirming = true } else { emit() } } label: { buttonContent }
                            .buttonStyle(CanvasPressedButtonStyle())
                    }
                }
                .clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
                .overlay(outline.map { CampaignCanvasRoundedShape(radius: cornerRadius).strokeBorder(CampaignCanvasTheme.shared.color($0.color, isDark: isDark), lineWidth: $0.width) })
            }
        }
        .alert(confirm.title ?? "", isPresented: $confirming) {
            Button(confirm.cancelLabel, role: .cancel) {}
            Button(confirm.confirmLabel, role: isDestructive ? .destructive : nil) { emit() }
        } message: { if let message = confirm.message { Text(message) } }
    }
    private var buttonContent: some View {
        ZStack {
            CampaignCanvasPaintView(paint: effectiveFill, isDark: isDark)
            CampaignCanvasTextView(block: label, isDark: isDark, onAction: onAction, colorOverride: destructiveColor)
        }.contentShape(CampaignCanvasRoundedShape(radius: cornerRadius))
    }
    private var effectiveFill: CampaignCanvasPaint {
        isDestructive && applyDestructiveStyling && isFilled ? .solid(danger) : style.fill
    }
    private var isFilled: Bool { if case .fill = style { true } else { false } }
    private var destructiveColor: UIColor? {
        guard isDestructive && applyDestructiveStyling else { return nil }
        return UIColor(isFilled ? Color.white : CampaignCanvasTheme.shared.color(danger, isDark: isDark))
    }
    private var outline: CampaignCanvasBorder? { if case .outline(_, let outline) = style { outline } else { nil } }
    private func emit() { onAction(CampaignCanvasActionRequest(actions: actions, elementId: isPrimary ? "cta_primary" : "cta_secondary", label: label.plainText, isPrimary: isPrimary)) }
}

private struct CanvasPressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(configuration.isPressed ? 0.78 : 1) }
}

private struct CanvasProgressRenderer: View {
    let box: CampaignCanvasBox; let valueMode: CampaignCanvasProgressValueMode
    let percent: String; let rangeStart: String; let rangeCurrent: String; let rangeEnd: String
    let indicator: CampaignCanvasPaint; let track: CampaignCanvasPaint; let cornerRadius: CampaignCanvasCornerRadius
    let animateOnAppear: CampaignCanvasAppearAnimation; let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    @State private var displayed: CGFloat = 0; @State private var appeared = false
    private var target: CGFloat {
        let raw: Double
        switch valueMode {
        case .percent: raw = Double(interpolate(percent, context: variables)) ?? 0
        case .range:
            let start = Double(interpolate(rangeStart, context: variables)) ?? 0
            let current = Double(interpolate(rangeCurrent, context: variables)) ?? 0
            let end = Double(interpolate(rangeEnd, context: variables)) ?? 0
            raw = end == start ? 0 : (current - start) / (end - start) * 100
        }
        return CGFloat(min(max(raw, 0), 100) / 100)
    }
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    CampaignCanvasPaintView(paint: track, isDark: isDark)
                    CampaignCanvasPaintView(paint: indicator, isDark: isDark).frame(width: geometry.size.width * displayed)
                }.clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
            }
        }
        .onAppear {
            if animateOnAppear.enabled {
                withAnimation(.easeOut(duration: Double(animateOnAppear.durationMs) / 1000)) { displayed = target }
            } else { displayed = target }
            appeared = true
        }
        .onChange(of: target) { value in if appeared { var transaction = Transaction(); transaction.disablesAnimations = true; withTransaction(transaction) { displayed = value } } }
    }
}

private struct CanvasLottieRenderer: View {
    let box: CampaignCanvasBox; let source: CampaignCanvasMediaSource; let autoplay: Bool; let loop: Bool; let fit: String; let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            let raw = CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark)
            let resolved = interpolate(raw, context: variables)
            if resolved.isEmpty { CanvasPlaceholder(label: "Lottie") }
            else if let url = URL(string: resolved) {
                CanvasRemoteLottie(url: url, placeholder: source.placeholder, autoplay: autoplay, loop: loop, fit: fit)
                    .id(resolved)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                CanvasPlaceholder(label: "Lottie")
            }
        }
    }
}

private struct CanvasRemoteLottie: View {
    let url: URL; let placeholder: ImagePlaceholder?; let autoplay: Bool; let loop: Bool; let fit: String
    @State private var failed = false
    var body: some View {
        Group {
            if autoplay {
                lottie.playing(loopMode: loop ? .loop : .playOnce)
                    .resizable()
                    .configure(\.contentMode, to: fit.uiContentMode)
            } else {
                lottie.resizable().configure(\.contentMode, to: fit.uiContentMode)
            }
        }
    }
    private var lottie: LottieView<CanvasLottiePlaceholder> {
        LottieView {
            do {
                if url.pathExtension.lowercased() == "lottie" { return try await DotLottieFile.loadedFrom(url: url).animationSource }
                guard let source = await LottieAnimation.loadedFrom(url: url)?.animationSource else {
                    failed = true
                    return nil
                }
                return source
            } catch {
                failed = true
                return nil
            }
        } placeholder: {
            CanvasLottiePlaceholder(failed: failed, placeholder: placeholder, fit: fit)
        }
    }
}

private struct CanvasLottiePlaceholder: View {
    let failed: Bool; let placeholder: ImagePlaceholder?; let fit: String
    var body: some View {
        if failed { CanvasPlaceholder(label: "Lottie") }
        else { BlurHashPlaceholderView(placeholder: placeholder, contentMode: fit == "contain" ? .fit : .fill) }
    }
}

private struct CanvasVideoRenderer: View {
    let box: CampaignCanvasBox; let source: CampaignCanvasMediaSource; let autoplay: Bool; let loop: Bool
    let muted: Bool; let showControls: Bool; let fit: String; let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    @State private var player: AVPlayer?; @State private var observer: NSObjectProtocol?
    private var url: String { interpolate(CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark), context: variables) }
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            if !url.isEmpty {
                ZStack { Color.black; if let player { CanvasPlayerController(player: player, controls: showControls, gravity: fit == "contain" ? .resizeAspect : .resizeAspectFill) } }
            }
        }
        .onAppear { setup() }
        .onChange(of: url) { _ in teardown(); setup() }
        .onDisappear { teardown() }
    }
    private func setup() {
        guard player == nil, let parsed = URL(string: url), !url.isEmpty else { return }
        let item = AVPlayerItem(url: parsed); let value = AVPlayer(playerItem: item); value.isMuted = muted; player = value
        if loop { observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in value.seek(to: .zero); value.play() } }
        if autoplay { value.play() }
    }
    private func teardown() { player?.pause(); player = nil; if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil }
}

private struct CanvasPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer; let controls: Bool; let gravity: AVLayerVideoGravity
    func makeUIViewController(context: Context) -> AVPlayerViewController { let value = AVPlayerViewController(); value.player = player; value.showsPlaybackControls = controls; value.videoGravity = gravity; return value }
    func updateUIViewController(_ value: AVPlayerViewController, context: Context) { value.player = player; value.showsPlaybackControls = controls; value.videoGravity = gravity }
}

private struct CanvasContainerRenderer: View {
    let fill: CampaignCanvasPaint; let cornerRadius: CampaignCanvasCornerRadius
    let border: CampaignCanvasBorder?; let shadow: CampaignCanvasShadow?; let isDark: Bool
    var body: some View {
        ZStack {
            if let shadow { CampaignCanvasShadowView(shadow: shadow, cornerRadius: cornerRadius, isDark: isDark) }
            CampaignCanvasPaintView(paint: fill, isDark: isDark)
                .clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
                .overlay(border.map { CampaignCanvasRoundedShape(radius: cornerRadius).strokeBorder(CampaignCanvasTheme.shared.color($0.color, isDark: isDark), lineWidth: $0.width) })
        }
    }
}

private struct CanvasDividerRenderer: View {
    let box: CampaignCanvasBox; let axis: CampaignCanvasDividerAxis; let pattern: CampaignCanvasDividerPattern
    let strokeCap: CampaignCanvasStrokeCap; let inset: CGFloat; let dashPattern: [CGFloat]; let color: CampaignColor; let isDark: Bool
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            Canvas { context, size in
                let horizontal = axis == .horizontal
                var path = Path(); path.move(to: horizontal ? CGPoint(x: inset, y: size.height / 2) : CGPoint(x: size.width / 2, y: inset)); path.addLine(to: horizontal ? CGPoint(x: size.width - inset, y: size.height / 2) : CGPoint(x: size.width / 2, y: size.height - inset))
                let thickness = horizontal ? size.height : size.width
                let dash: [CGFloat] = pattern == .solid ? [] : (pattern == .dotted ? [0, max(thickness, dashPattern.dropFirst().first ?? 4)] : dashPattern)
                context.stroke(path, with: .color(CampaignCanvasTheme.shared.color(color, isDark: isDark)), style: StrokeStyle(lineWidth: thickness, lineCap: strokeCap.lineCap, dash: dash))
            }
        }
    }
}

private struct CampaignCanvasBoxView<Content: View>: View {
    let box: CampaignCanvasBox; let isDark: Bool; var clipsContent = true; @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            if let shadow = box.shadow { CampaignCanvasShadowView(shadow: shadow, cornerRadius: box.cornerRadius, isDark: isDark) }
            Group {
                if clipsContent { contentLayer.clipShape(CampaignCanvasRoundedShape(radius: box.cornerRadius)) }
                else { contentLayer }
            }
            .overlay(box.border.map { CampaignCanvasRoundedShape(radius: box.cornerRadius).strokeBorder(CampaignCanvasTheme.shared.color($0.color, isDark: isDark), lineWidth: $0.width) })
        }
    }
    private var contentLayer: some View {
        ZStack {
            CampaignCanvasPaintView(paint: box.fill, isDark: isDark)
                .clipShape(CampaignCanvasRoundedShape(radius: box.cornerRadius))
            content().padding(EdgeInsets(top: box.padding.top, leading: box.padding.left, bottom: box.padding.bottom, trailing: box.padding.right))
        }
    }
}

private struct CampaignCanvasShadowView: View {
    let shadow: CampaignCanvasShadow; let cornerRadius: CampaignCanvasCornerRadius; let isDark: Bool
    var outsideOnly = false
    @ViewBuilder
    var body: some View {
        if shadow.blur > 0 || shadow.spread > 0 || shadow.offsetX != 0 || shadow.offsetY != 0 {
            if outsideOnly {
                ZStack {
                    shadowShape
                    CampaignCanvasRoundedShape(radius: cornerRadius)
                        .fill(Color.black)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            } else {
                shadowShape
            }
        }
    }
    private var shadowShape: some View {
        CampaignCanvasRoundedShape(radius: cornerRadius)
            .fill(CampaignCanvasTheme.shared.color(shadow.color, isDark: isDark))
            .padding(-shadow.spread)
            .blur(radius: shadow.blur / 2)
            .offset(x: shadow.offsetX, y: shadow.offsetY)
    }
}

private struct CampaignCanvasPaintView: View {
    let paint: CampaignCanvasPaint; let isDark: Bool
    var body: some View {
        switch paint {
        case .solid(let color): CampaignCanvasTheme.shared.color(color, isDark: isDark)
        case .gradient(let type, let angle, let x, let y, let radius, let start, let end, let stops): CampaignCanvasGradientView(type: type, angle: angle, centerX: x, centerY: y, radius: radius, start: start, end: end, stops: stops, isDark: isDark)
        case .image(let source, let x, let y, let scale): FocalCanvasImage(source: source, isDark: isDark, fit: "cover", x: x, y: y, scale: scale)
        case .none: Color.clear
        }
    }
}

private struct CampaignCanvasGradientView: View {
    let type: CampaignCanvasGradientType; let angle: CGFloat; let centerX: CGFloat; let centerY: CGFloat
    let radius: CGFloat; let start: CGFloat; let end: CGFloat; let stops: [CampaignCanvasGradientStop]; let isDark: Bool
    var body: some View {
        if stops.isEmpty { Color.clear }
        else if stops.count == 1 { CampaignCanvasTheme.shared.color(stops[0].color, isDark: isDark) }
        else {
            GeometryReader { geometry in
                switch type {
                case .linear:
                    Canvas { context, size in
                        let radians = angle * .pi / 180; let direction = CGVector(dx: sin(radians), dy: -cos(radians)); let extent = abs(direction.dx) * size.width + abs(direction.dy) * size.height; let center = CGPoint(x: size.width / 2, y: size.height / 2); let delta = CGPoint(x: direction.dx * extent / 2, y: direction.dy * extent / 2)
                        context.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(Gradient(stops: gradientStops), startPoint: CGPoint(x: center.x - delta.x, y: center.y - delta.y), endPoint: CGPoint(x: center.x + delta.x, y: center.y + delta.y)))
                    }
                case .radial:
                    RadialGradient(gradient: Gradient(stops: gradientStops), center: UnitPoint(x: centerX, y: centerY), startRadius: 0, endRadius: min(geometry.size.width, geometry.size.height) * radius)
                case .sweep:
                    AngularGradient(gradient: Gradient(stops: gradientStops), center: UnitPoint(x: centerX, y: centerY), startAngle: .degrees(start - 90), endAngle: .degrees(end - 90))
                }
            }
        }
    }
    private var gradientStops: [Gradient.Stop] { stops.map { .init(color: CampaignCanvasTheme.shared.color($0.color, isDark: isDark), location: $0.offset) } }
}

private struct FocalCanvasImage: View {
    let source: CampaignCanvasMediaSource; let isDark: Bool; let fit: String
    let x: CGFloat; let y: CGFloat; let scale: CGFloat; var tint: CampaignColor? = nil; var failureLabel: String? = nil
    @Environment(\.digiaVariables) private var variables
    @State private var failedURL: String?
    var body: some View {
        let raw = CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark); let resolved = interpolate(raw, context: variables)
        if resolved.isEmpty || failedURL == resolved { if let failureLabel { CanvasPlaceholder(label: failureLabel) } }
        else if URL(string: resolved) == nil { if let failureLabel { CanvasPlaceholder(label: failureLabel) } }
        else {
            GeometryReader { geometry in
                WebImage(url: URL(string: resolved)) { image in
                    image.resizable().renderingMode(tint == nil ? .original : .template)
                } placeholder: {
                    BlurHashPlaceholderView(placeholder: source.placeholder, contentMode: fit == "contain" ? .fit : .fill)
                }
                .onFailure { _ in failedURL = resolved }
                .modifier(CanvasImageFit(fit: fit))
                .foregroundStyle(tint.map { CampaignCanvasTheme.shared.color($0, isDark: isDark) } ?? .clear)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: focalAlignment(x: x, y: y))
                .scaleEffect(max(0.1, scale), anchor: UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)))
                .clipped()
            }
            .onChange(of: resolved) { _ in failedURL = nil }
        }
    }
}

private struct CanvasImageFit: ViewModifier {
    let fit: String
    @ViewBuilder func body(content: Content) -> some View { switch fit { case "contain": content.scaledToFit(); case "fill": content; default: content.scaledToFill() } }
}

private struct CampaignCanvasRoundedShape: InsettableShape {
    let radius: CampaignCanvasCornerRadius
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> CampaignCanvasRoundedShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let inset = min(max(0, insetAmount), min(rect.width, rect.height) / 2)
        let rect = rect.insetBy(dx: inset, dy: inset)
        let radiusLimit = min(rect.width, rect.height) / 2
        let topLeft = min(max(0, radius.topLeft - inset), radiusLimit)
        let topRight = min(max(0, radius.topRight - inset), radiusLimit)
        let bottomRight = min(max(0, radius.bottomRight - inset), radiusLimit)
        let bottomLeft = min(max(0, radius.bottomLeft - inset), radiusLimit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRight), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topLeft, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct CanvasChildBoundsModifier: ViewModifier {
    let clips: Bool
    @ViewBuilder func body(content: Content) -> some View { if clips { content.clipped() } else { content } }
}

private struct CanvasPlaceholder: View {
    let label: String
    var body: some View { ZStack { RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#F1F1F5") ?? Color(.systemGray6)); Text(label).font(.system(size: 11)).foregroundStyle(Color(hex: "#9A9AAD") ?? .secondary) } }
}

private extension CampaignCanvasHorizontalAlign {
    var uiTextAlignment: NSTextAlignment { switch self { case .left: .left; case .center: .center; case .right: .right } }
}
private extension CampaignCanvasTextBlock {
    var alignment: Alignment {
        let horizontal: HorizontalAlignment = horizontalAlign == .left ? .leading : (horizontalAlign == .right ? .trailing : .center)
        let vertical: VerticalAlignment = verticalAlign == .top ? .top : (verticalAlign == .bottom ? .bottom : .center)
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}
private extension CampaignCanvasStrokeCap { var lineCap: CGLineCap { switch self { case .butt: .butt; case .round: .round; case .square: .square } } }
private extension String { var uiContentMode: UIView.ContentMode { switch self { case "contain": .scaleAspectFit; case "fill": .scaleToFill; default: .scaleAspectFill } } }
private func focalAlignment(x: CGFloat, y: CGFloat) -> Alignment { Alignment(horizontal: x < 0.34 ? .leading : (x > 0.66 ? .trailing : .center), vertical: y < 0.34 ? .top : (y > 0.66 ? .bottom : .center)) }
