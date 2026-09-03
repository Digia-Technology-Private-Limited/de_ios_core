import AVFoundation
import AVKit
import SwiftUI
import UIKit

@_implementationOnly import Lottie
@_implementationOnly import SDWebImageSwiftUI

private let maxFloatingCanvasUpscale: CGFloat = 1.15
private let canvasTextSpanElementID = "canvas_text_span"

private struct TimerRemainingSecondsKey: EnvironmentKey {
    static let defaultValue: Int64? = nil
}

extension EnvironmentValues {
    var timerRemainingSeconds: Int64? {
        get { self[TimerRemainingSecondsKey.self] }
        set { self[TimerRemainingSecondsKey.self] = newValue }
    }
}

private struct CanvasVideoUsesStoryPlaybackKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var canvasVideoUsesStoryPlayback: Bool {
        get { self[CanvasVideoUsesStoryPlaybackKey.self] }
        set { self[CanvasVideoUsesStoryPlaybackKey.self] = newValue }
    }
}

internal func anchorlessDesignScale(hostWidth: CGFloat, designWidth: CGFloat) -> CGFloat? {
    guard hostWidth.isFinite, hostWidth > 0,
        designWidth.isFinite, designWidth > 0
    else { return nil }
    let scale = hostWidth / designWidth
    guard scale.isFinite, scale > 0 else { return nil }
    return min(scale, maxFloatingCanvasUpscale)
}

struct CampaignCanvasView: View {
    let canvas: CampaignCanvas
    let surface: NudgeSurface
    let designWidth: CGFloat
    var runtimeViewportWidth: CGFloat? = nil
    let availableSize: CGSize
    let onAction: (CampaignCanvasActionRequest) -> Void
    var showBackground = true
    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    private var designScale: CGFloat {
        let base = (runtimeViewportWidth ?? availableSize.width) / max(designWidth, 1)
        return surface.isBottomSheet || surface.isFullScreen ? base : min(base, maxFloatingCanvasUpscale)
    }
    var fittedScale: CGFloat {
        if surface.isFullScreen {
            // Fill the content viewport uniformly; its centered, clipped parent
            // crops overflow without changing the authored composition.
            return max(availableSize.width / max(canvas.width, 1),
                       availableSize.height / max(canvas.height, 1))
        }
        let naturalWidth = max(canvas.width * designScale, 1)
        let naturalHeight = max(canvas.height * designScale, 1)
        return designScale
            * min(1, availableSize.width / naturalWidth, availableSize.height / naturalHeight)
    }

    var body: some View {
        CampaignCanvasStage(
            canvas: canvas,
            authoredCornerRadius: surface.isFullScreen ? 0 : surface.cornerRadius / max(designScale, 0.001),
            isDark: theme.isDark(colorScheme),
            showBackground: showBackground,
            onAction: onAction
        )
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .scaleEffect(fittedScale, anchor: surface.isFullScreen ? .center : .topLeading)
        .frame(
            width: canvas.width * fittedScale,
            height: canvas.height * fittedScale,
            alignment: surface.isFullScreen ? .center : .topLeading
        )
    }
}

/// Renders an authored Canvas inside a slot.
///
/// Deliberately separate from `CampaignCanvasView`. That view takes a
/// `NudgeSurface` and branches on `isBottomSheet` / `cornerRadius`, and it fits
/// the canvas against the available *screen* box — correct for an overlay and
/// wrong here twice over: an inline card lives inside a scrolling list where the
/// available height is unbounded, so fitting to the viewport hands back a
/// screen-sized slice and shoves the host's own content off the page. It also
/// caps the scale at `maxFloatingCanvasUpscale`, which would stop a card from
/// filling the slot the developer sized for it.
///
/// The rule here comes entirely from width:
///
/// ```text
/// inner  = slotWidth - margin.horizontal
/// scale  = inner / designWidth
/// height = canvas.height * scale + margin.vertical
/// ```
///
/// A card spans its design frame, so a horizontal margin cannot make the canvas
/// narrower — it narrows the room the card has, and the whole surface scales
/// down uniformly to fit, type included. Side margin therefore reads as "make
/// this card smaller" rather than "inset it", which is why the authored default
/// is zero and a new card fills its slot.
///
/// Height is *reported*, never *consumed*, which is why `InlineCanvasCardLayout`
/// exists instead of an `aspectRatio(contentMode: .fit)`. The host measures this
/// card to size the slot around it, so a rule that also read the offered height
/// would close a loop: a re-triggered campaign lands in a slot still sized for
/// whatever was there before, aspect-fit trades width away to fit that stale
/// box, and the host then measures the narrower card and keeps the stale height.
/// The result is a smaller card that is perfectly self-consistent and never
/// recovers until the screen remounts.
struct InlineCampaignCanvasView: View {
    let canvas: CampaignCanvas
    let designWidth: CGFloat
    let cornerRadius: CGFloat
    let margin: InlineCanvasMargin
    let onAction: (CampaignCanvasActionRequest) -> Void

    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    private var designFrame: CGFloat { max(designWidth, canvas.width) }

    var body: some View {
        // `Layout` needs iOS 16. Unreachable below it in practice: `Digia`
        // initialization no-ops before iOS 17, so no campaign ever reaches a
        // slot on an older OS — the same gate the inline carousel renderer uses.
        if #available(iOS 16, *) {
            InlineCanvasCardLayout(
                canvasHeight: canvas.height,
                designFrame: designFrame,
                margin: margin
            ) {
                card
            }
        }
    }

    private var card: some View {
        GeometryReader { proxy in
            let inner = proxy.size.width - CGFloat(margin.horizontal)
            let scale = (inner > 0 && designFrame > 0) ? inner / designFrame : 0
            CampaignCanvasStage(
                canvas: canvas,
                authoredCornerRadius: cornerRadius,
                isDark: theme.isDark(colorScheme),
                showBackground: true,
                onAction: onAction
            )
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(
                width: canvas.width * scale,
                height: canvas.height * scale,
                alignment: .topLeading
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius * scale, style: .continuous))
            .padding(.leading, CGFloat(margin.left))
            .padding(.trailing, CGFloat(margin.right))
            .padding(.top, CGFloat(margin.top))
            .padding(.bottom, CGFloat(margin.bottom))
        }
    }
}

/// Sizes an inline canvas card from the offered *width* alone.
///
/// A slot has no intrinsic height of its own, so the card reports one — and a
/// container that reported a height derived from the height it was offered would
/// let a stale slot size pin the card at that size forever. Taking only
/// `proposal.width` makes the reported height a pure function of the width,
/// so a re-trigger into a stale slot corrects itself on the next pass instead of
/// settling into a smaller card. Mirrors `InlineCarouselImageLayout`.
@available(iOS 16, *)
private struct InlineCanvasCardLayout: Layout {
    let canvasHeight: CGFloat
    let designFrame: CGFloat
    let margin: InlineCanvasMargin

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = resolvedWidth(proposal)
        return CGSize(width: width, height: height(forWidth: width))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }

    /// An unspecified or infinite width proposal is a question about the card's
    /// *ideal* size, and the honest answer is the size it was authored at —
    /// answering 0 there would report a card with no height at all.
    private func resolvedWidth(_ proposal: ProposedViewSize) -> CGFloat {
        guard let width = proposal.width, width.isFinite else {
            return designFrame + CGFloat(margin.horizontal)
        }
        return width
    }

    private func height(forWidth width: CGFloat) -> CGFloat {
        let inner = width - CGFloat(margin.horizontal)
        guard inner > 0, designFrame > 0 else { return CGFloat(margin.vertical) }
        return canvasHeight * (inner / designFrame) + CGFloat(margin.vertical)
    }
}

/// A guide Canvas body and pointer rendered as one clipped surface. Flutter's
/// guide renderer paints the background once across the rounded body + pointer
/// union, so gradients/images do not become a separately painted arrow.
struct GuideCanvasUnionSurface: View {
    let canvas: CampaignCanvas
    let designWidth: CGFloat
    let viewportWidth: CGFloat
    let availableSize: CGSize
    let resolvedScale: CGFloat?
    let cornerRadius: CGFloat
    let pointerDirection: GuideCanvasPointerDirection?
    let pointerSize: CGFloat
    let pointerCenter: CGFloat?
    let borderColor: Color
    let borderWidth: CGFloat
    let shadowRadius: CGFloat
    let onAction: (CampaignCanvasActionRequest) -> Void
    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    private var scale: CGFloat {
        resolvedScale ?? guideCanvasScale(
            canvas: canvas,
            designWidth: designWidth,
            viewportWidth: viewportWidth,
            availableSize: availableSize,
            pointerDirection: pointerDirection,
            pointerSize: pointerSize
        )
    }

    private var bodySize: CGSize {
        CGSize(width: canvas.width * scale, height: canvas.height * scale)
    }

    private var scaledPointerSize: CGFloat { max(0, pointerSize * scale) }
    private var scaledCornerRadius: CGFloat { max(0, cornerRadius * scale) }
    private var scaledBorderWidth: CGFloat { max(0, borderWidth * scale) }
    private var scaledShadowRadius: CGFloat { max(0, shadowRadius * scale) }

    private var outerSize: CGSize {
        guard pointerDirection != nil else { return bodySize }
        let horizontal = pointerDirection == .left || pointerDirection == .right
        return CGSize(
            width: bodySize.width + (horizontal ? scaledPointerSize : 0),
            height: bodySize.height + (horizontal ? 0 : scaledPointerSize)
        )
    }

    private var bodyOffset: CGSize {
        switch pointerDirection {
        case .up: return CGSize(width: 0, height: scaledPointerSize)
        case .left: return CGSize(width: scaledPointerSize, height: 0)
        default: return .zero
        }
    }

    var body: some View {
        let isDark = theme.isDark(colorScheme)
        let shape = GuideCanvasUnionShape(
            bodySize: bodySize,
            pointerDirection: pointerDirection,
            pointerSize: scaledPointerSize,
            pointerCenter: pointerCenter,
            cornerRadius: scaledCornerRadius
        )
        ZStack(alignment: .topLeading) {
            CampaignCanvasPaintView(paint: canvas.background, isDark: isDark)
            CampaignCanvasStage(
                canvas: canvas,
                authoredCornerRadius: cornerRadius,
                isDark: isDark,
                showBackground: false,
                onAction: onAction
            )
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: bodySize.width, height: bodySize.height, alignment: .topLeading)
            .offset(bodyOffset)
        }
        .frame(width: outerSize.width, height: outerSize.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.stroke(borderColor, lineWidth: scaledBorderWidth))
        .shadow(radius: scaledShadowRadius)
    }
}

private func guideCanvasScale(
    canvas: CampaignCanvas,
    designWidth: CGFloat,
    viewportWidth: CGFloat,
    availableSize: CGSize,
    pointerDirection: GuideCanvasPointerDirection?,
    pointerSize: CGFloat
) -> CGFloat {
    guard
        let designScale = anchorlessDesignScale(
            hostWidth: viewportWidth,
            designWidth: designWidth
        )
    else { return 0 }
    let horizontal = pointerDirection == .left || pointerDirection == .right
    let arrowSize = pointerDirection == nil ? 0 : max(0, pointerSize)
    let authoredWidth = canvas.width + (horizontal ? arrowSize : 0)
    let authoredHeight = canvas.height + (horizontal ? 0 : arrowSize)
    let widthScale = max(0, availableSize.width) / max(authoredWidth * designScale, 1)
    let heightScale = max(0, availableSize.height) / max(authoredHeight * designScale, 1)
    let fittedScale = designScale * min(1, widthScale, heightScale)
    return fittedScale.isFinite && fittedScale > 0 ? fittedScale : 0
}

private struct GuideCanvasUnionShape: Shape {
    let bodySize: CGSize
    let pointerDirection: GuideCanvasPointerDirection?
    let pointerSize: CGFloat
    let pointerCenter: CGFloat?
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let horizontal = pointerDirection == .left || pointerDirection == .right
        let bodyRect = CGRect(
            x: pointerDirection == .left ? pointerSize : 0,
            y: pointerDirection == .up ? pointerSize : 0,
            width: bodySize.width,
            height: bodySize.height
        )
        let radius = min(max(0, cornerRadius), min(bodyRect.width, bodyRect.height) / 2)
        guard let pointerDirection, pointerSize > 0 else {
            return Path(roundedRect: bodyRect, cornerRadius: radius)
        }

        let crossExtent = horizontal ? bodyRect.height : bodyRect.width
        let clearance = min(crossExtent / 2, max(pointerSize, cornerRadius + pointerSize))
        let requested = pointerCenter ?? (horizontal ? bodyRect.midY : bodyRect.midX)
        let center = min(
            max(requested, (horizontal ? bodyRect.minY : bodyRect.minX) + clearance),
            (horizontal ? bodyRect.maxY : bodyRect.maxX) - clearance
        )
        var path = Path()
        switch pointerDirection {
        case .up:
            path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
            path.addLine(to: CGPoint(x: center - pointerSize, y: bodyRect.minY))
            path.addLine(to: CGPoint(x: center, y: bodyRect.minY - pointerSize))
            path.addLine(to: CGPoint(x: center + pointerSize, y: bodyRect.minY))
            path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
            addRightAndBottomEdges(to: &path, bodyRect: bodyRect, radius: radius)
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
            )
        case .down:
            path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
            addTopAndRightEdges(to: &path, bodyRect: bodyRect, radius: radius)
            path.addLine(to: CGPoint(x: center + pointerSize, y: bodyRect.maxY))
            path.addLine(to: CGPoint(x: center, y: bodyRect.maxY + pointerSize))
            path.addLine(to: CGPoint(x: center - pointerSize, y: bodyRect.maxY))
            path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
            )
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
            )
        case .left:
            path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
            addTopAndRightEdges(to: &path, bodyRect: bodyRect, radius: radius)
            path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
            )
            path.addLine(to: CGPoint(x: bodyRect.minX, y: center + pointerSize))
            path.addLine(to: CGPoint(x: bodyRect.minX - pointerSize, y: center))
            path.addLine(to: CGPoint(x: bodyRect.minX, y: center - pointerSize))
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
            )
        case .right:
            path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
            path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius),
                control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
            )
            path.addLine(to: CGPoint(x: bodyRect.maxX, y: center - pointerSize))
            path.addLine(to: CGPoint(x: bodyRect.maxX + pointerSize, y: center))
            path.addLine(to: CGPoint(x: bodyRect.maxX, y: center + pointerSize))
            path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY),
                control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
            )
            path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
            )
            path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
            path.addQuadCurve(
                to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY),
                control: CGPoint(x: bodyRect.minX, y: bodyRect.minY)
            )
        }
        path.closeSubpath()
        return path
    }

    private func addTopAndRightEdges(to path: inout Path, bodyRect: CGRect, radius: CGFloat) {
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        )
    }

    private func addRightAndBottomEdges(to path: inout Path, bodyRect: CGRect, radius: CGFloat) {
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX, y: bodyRect.minY + radius),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.minY)
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY),
            control: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: bodyRect.minX, y: bodyRect.maxY - radius),
            control: CGPoint(x: bodyRect.minX, y: bodyRect.maxY)
        )
    }
}

struct CampaignCanvasStage: View {
    let canvas: CampaignCanvas
    let authoredCornerRadius: CGFloat
    let isDark: Bool
    let showBackground: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    /// Whether the canvas's own background absorbs touches that no child wanted.
    ///
    /// True everywhere but a story floater's window. Children already opt in and out
    /// individually (`child.isHitTestable` below), so the background is the only thing
    /// standing between "the author left this spot empty" and whatever is behind the
    /// canvas — and for every other surface it *should* stand there: a tap on a
    /// dialog's own background must not fall through to the barrier and dismiss it.
    ///
    /// A floating window is the one surface where falling through is the point. The
    /// window sits on a drag/tap shield that opens the story, so empty canvas has to
    /// reach it while a button or tap region on that same canvas still takes its own
    /// touch.
    var backgroundTakesTouches = true

    /// Where a tap that carries `Action.showStory` is routed.
    ///
    /// The element that fires it is usually a *sibling* of the story rail rather
    /// than a descendant, so the rail can never hear the tap itself. The stage
    /// owns every child, which makes it the one place that sees both.
    @State private var storyOpenIndex: Int?

    private func dispatch(_ request: CampaignCanvasActionRequest) {
        for action in request.actions {
            if case .showStory(let index) = action { storyOpenIndex = index }
        }
        // Forwarded whole, so the tap's analytics and any other actions on it
        // behave exactly as they would anywhere else; the runner has no case for
        // `showStory` and ignores it.
        onAction(request)
    }

    /// The canvas's story rail, if it has one. At most one: the dashboard places
    /// exactly one per campaign and forbids adding another.
    private var story: CampaignCanvasWidget? {
        canvas.children.lazy.compactMap { child -> CampaignCanvasWidget? in
            guard case .widget(_, _, let widget) = child, case .story = widget else { return nil }
            return widget
        }.first
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showBackground {
                CampaignCanvasPaintView(paint: canvas.background, isDark: isDark)
                    .allowsHitTesting(backgroundTakesTouches)
            }
            ForEach(canvas.children) { child in
                CanvasChildView(child: child, isDark: isDark, onAction: dispatch)
                    .frame(
                        width: child.rect.width, height: child.rect.height, alignment: .topLeading
                    )
                    .modifier(CanvasChildBoundsModifier(clips: child.clipsToAuthoredRect))
                    .allowsHitTesting(child.isHitTestable)
                    .offset(x: child.rect.x, y: child.rect.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: max(0, authoredCornerRadius)))
        .fullScreenCover(
            isPresented: Binding(
                get: { storyOpenIndex != nil && story != nil },
                set: { if !$0 { storyOpenIndex = nil } }
            )
        ) {
            if case .story(
                _, let pages, _, _, _, _, _, let restartOnCompleted, let startMuted, let chrome
            ) = story, !pages.isEmpty {
                CanvasStoryViewer(
                    pages: pages,
                    chrome: chrome,
                    // Clamped rather than trusted: the authored number can outlive
                    // the story it named if the author later deletes one.
                    initialIndex: min(max(0, storyOpenIndex ?? 0), pages.count - 1),
                    restartOnCompleted: restartOnCompleted,
                    startMuted: startMuted,
                    isDark: isDark,
                    onAction: onAction,
                    onDismiss: { storyOpenIndex = nil },
                    safeAreaInsets: activeFloaterWindowSafeAreaInsets
                )
                .ignoresSafeArea()
            }
        }
    }
}

private struct CanvasChildView: View {
    let child: CampaignCanvasChild
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    var body: some View {
        switch child {
        case .widget(_, _, let widget):
            CampaignCanvasRendererRegistry.render(widget, isDark: isDark, onAction: onAction)
        case .tapRegion(let id, _, let actions):
            Color.clear.contentShape(Rectangle()).onTapGesture {
                onAction(CampaignCanvasActionRequest(actions: actions, elementId: id))
            }
        }
    }
}

@MainActor
enum CampaignCanvasRendererRegistry {
    typealias Renderer = (
        CampaignCanvasWidget, Bool, @escaping (CampaignCanvasActionRequest) -> Void
    ) -> AnyView
    private static let renderers: [String: Renderer] = [
        "text": { widget, dark, action in
            guard case .text(let box, let block, let shadow) = widget else {
                return AnyView(EmptyView())
            }
            return AnyView(
                CanvasTextRenderer(
                    box: box, block: block, shadow: shadow, isDark: dark, onAction: action))
        },
        "image": { widget, dark, action in
            guard
                case .image(let box, let source, let fit, let x, let y, let scale, let tint) =
                    widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasImageRenderer(
                    box: box, source: source, fit: fit, positionX: x, positionY: y, scale: scale,
                    tint: tint, isDark: dark))
        },
        "button": { widget, dark, action in
            guard
                case .button(
                    let box, let label, let radius, let style, let shadow, let primary,
                    let destructive, let apply, let actions, let confirm) = widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasButtonRenderer(
                    box: box, label: label, cornerRadius: radius, style: style, shadow: shadow,
                    isPrimary: primary, isDestructive: destructive, applyDestructiveStyling: apply,
                    actions: actions, confirm: confirm, isDark: dark, onAction: action))
        },
        "progress": { widget, dark, _ in
            guard
                case .progress(
                    let box, let mode, let percent, let start, let current, let end, let indicator,
                    let track, let radius, let animation) = widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasProgressRenderer(
                    box: box, valueMode: mode, percent: percent, rangeStart: start,
                    rangeCurrent: current, rangeEnd: end, indicator: indicator, track: track,
                    cornerRadius: radius, animateOnAppear: animation, isDark: dark))
        },
        "lottie": { widget, dark, _ in
            guard case .lottie(let box, let source, let autoplay, let loop, let fit) = widget else {
                return AnyView(EmptyView())
            }
            return AnyView(
                CanvasLottieRenderer(
                    box: box, source: source, autoplay: autoplay, loop: loop, fit: fit, isDark: dark
                ))
        },
        "video": { widget, dark, _ in
            guard
                case .video(
                    let box, let source, let autoplay, let loop, let muted, let controls, let fit) =
                    widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasVideoRenderer(
                    box: box, source: source, autoplay: autoplay, loop: loop, muted: muted,
                    showControls: controls, fit: fit, isDark: dark))
        },
        "container": { widget, dark, _ in
            guard case .container(let fill, let radius, let border, let shadow) = widget else {
                return AnyView(EmptyView())
            }
            return AnyView(
                CanvasContainerRenderer(
                    fill: fill, cornerRadius: radius, border: border, shadow: shadow, isDark: dark))
        },
        "divider": { widget, dark, _ in
            guard
                case .divider(
                    let box, let axis, let pattern, let cap, let inset, let dash, let color) =
                    widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasDividerRenderer(
                    box: box, axis: axis, pattern: pattern, strokeCap: cap, inset: inset,
                    dashPattern: dash, color: color, isDark: dark))
        },
        "carousel": { widget, dark, onAction in
            guard case .carousel = widget else { return AnyView(EmptyView()) }
            return AnyView(CanvasCarouselRenderer(widget: widget, isDark: dark, onAction: onAction))
        },
        "story": { widget, dark, onAction in
            guard case .story = widget else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasStoryRailRenderer(widget: widget, isDark: dark, onAction: onAction))
        },
        "storyProgress": { widget, dark, _ in
            guard
                case .storyProgress(_, let active, let track, let barHeight, let radius, let gap) =
                    widget
            else { return AnyView(EmptyView()) }
            return AnyView(
                CanvasStoryProgressRenderer(
                    activeColor: active, trackColor: track, barHeight: barHeight,
                    cornerRadius: radius, gap: gap, isDark: dark))
        },
        "storyClose": { widget, dark, _ in
            guard case .storyClose(_, let visible, let icon, let background) = widget else {
                return AnyView(EmptyView())
            }
            return AnyView(
                CanvasStoryChromeButton(
                    kind: .close, visible: visible, iconColor: icon, backgroundColor: background,
                    isDark: dark))
        },
        "storyMute": { widget, dark, _ in
            guard case .storyMute(_, let visible, let icon, let background) = widget else {
                return AnyView(EmptyView())
            }
            return AnyView(
                CanvasStoryChromeButton(
                    kind: .mute, visible: visible, iconColor: icon, backgroundColor: background,
                    isDark: dark))
        },
        "timer": { widget, dark, _ in
            guard case .timer = widget else { return AnyView(EmptyView()) }
            return AnyView(CanvasTimerRenderer(widget: widget, isDark: dark))
        },
    ]

    static func render(
        _ widget: CampaignCanvasWidget, isDark: Bool,
        onAction: @escaping (CampaignCanvasActionRequest) -> Void
    ) -> AnyView {
        let key: String
        switch widget {
        case .text: key = "text"
        case .image: key = "image"
        case .button: key = "button"
        case .progress: key = "progress"
        case .lottie: key = "lottie"
        case .video: key = "video"
        case .container: key = "container"
        case .divider: key = "divider"
        case .carousel: key = "carousel"
        case .story: key = "story"
        case .storyProgress: key = "storyProgress"
        case .storyClose: key = "storyClose"
        case .storyMute: key = "storyMute"
        case .timer: key = "timer"
        }
        guard let renderer = renderers[key] else {
            preconditionFailure("Missing Campaign Canvas renderer for \(key)")
        }
        return renderer(widget, isDark, onAction)
    }

    static func hasRenderer(for widget: CampaignCanvasWidget) -> Bool {
        let key: String
        switch widget {
        case .text: key = "text"
        case .image: key = "image"
        case .button: key = "button"
        case .progress: key = "progress"
        case .lottie: key = "lottie"
        case .video: key = "video"
        case .container: key = "container"
        case .divider: key = "divider"
        case .carousel: key = "carousel"
        case .story: key = "story"
        case .storyProgress: key = "storyProgress"
        case .storyClose: key = "storyClose"
        case .storyMute: key = "storyMute"
        case .timer: key = "timer"
        }
        return renderers[key] != nil
    }
}

private struct CanvasTimerRenderer: View {
    let widget: CampaignCanvasWidget
    let isDark: Bool
    @Environment(\.timerRemainingSeconds) private var remainingSeconds

    var body: some View {
        if case .timer(
            _, let preset, let separator, let units, let labels, let sharedStyle, let overrides
        ) = widget, let remainingSeconds {
            let values = timerUnitValues(remainingSeconds: remainingSeconds, visibility: units)
            GeometryReader { geometry in
                let unitCount = max(1, CampaignTimerUnit.allCases.filter { units[$0] != .hide }.count)
                let boxWidth = max(0, (geometry.size.width - CGFloat(unitCount - 1) * 4) / CGFloat(unitCount))
                HStack(spacing: 4) {
                    ForEach(Array(values.enumerated()), id: \.element.0) { index, value in
                        if index > 0 && preset == "text" {
                            Text(separator)
                                .foregroundStyle(color((overrides[value.0] ?? sharedStyle).digitColor))
                        }
                        unitView(
                            value: value.1,
                            label: labels[value.0] ?? "",
                            style: overrides[value.0] ?? sharedStyle,
                            boxed: preset == "unitBoxes"
                        )
                        .frame(width: preset == "unitBoxes" ? boxWidth : nil)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Countdown timer")
        }
    }

    @ViewBuilder
    private func unitView(
        value: Int64,
        label: String,
        style: CampaignCanvasTimerUnitStyle,
        boxed: Bool
    ) -> some View {
        let content = VStack(spacing: 1) {
            Text(String(format: "%02lld", value))
                .font(font(style.digitTypography, fallbackSize: 16, fallbackWeight: 400))
                .tracking(style.digitTypography?.letterSpacing ?? 0)
                .frame(height: timerLineHeight(style.digitTypography, fallbackSize: 16))
                .foregroundStyle(color(style.digitColor))
                .monospacedDigit()
                .lineLimit(1)
            Text(label)
                .font(font(style.labelTypography, fallbackSize: 10, fallbackWeight: 400))
                .tracking(style.labelTypography?.letterSpacing ?? 0)
                .frame(height: timerLineHeight(style.labelTypography, fallbackSize: 10))
                .foregroundStyle(color(style.labelColor))
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)

        if boxed {
            CampaignCanvasBoxView(
                box: CampaignCanvasBox(
                    fill: style.boxFill,
                    cornerRadius: style.cornerRadius
                ),
                isDark: isDark
            ) { content }
        } else { content }
    }

    private func color(_ value: CampaignColor?) -> Color {
        value.map { CampaignCanvasTheme.shared.color($0, isDark: isDark) } ?? .primary
    }

    private func font(
        _ typography: CampaignTypography?,
        fallbackSize: CGFloat,
        fallbackWeight: Int
    ) -> Font {
        Font(SDKInstance.shared.font.resolve(
            size: Double(typography?.fontSize ?? fallbackSize),
            weight: typography?.fontWeight ?? fallbackWeight,
            italic: false,
            fallbackFamily: typography?.fontFamily
        ))
    }
}

func timerLineHeight(_ typography: CampaignTypography?, fallbackSize: CGFloat) -> CGFloat? {
    guard let lineHeight = typography?.lineHeight else { return nil }
    let height = lineHeight <= 4 ? lineHeight * (typography?.fontSize ?? fallbackSize) : lineHeight
    return height.isFinite && height > 0 ? height : nil
}

func timerUnitValues(
    remainingSeconds: Int64,
    visibility: [CampaignTimerUnit: CampaignTimerUnitVisibility]
) -> [(CampaignTimerUnit, Int64)] {
    let factors: [(CampaignTimerUnit, Int64)] = [
        (.days, 86_400), (.hours, 3_600), (.minutes, 60), (.seconds, 1)
    ]
    let configured = factors.filter { visibility[$0.0] != .hide }
    guard let smallest = configured.last?.1 else { return [] }
    let safe = max(0, remainingSeconds)
    let rounded = ((safe + smallest - 1) / smallest) * smallest
    let values = configured.enumerated().map { index, entry -> (CampaignTimerUnit, Int64) in
        let higher = index > 0 ? configured[index - 1].1 : Int64.max
        let value = index == 0 ? rounded / entry.1 : (rounded % higher) / entry.1
        return (entry.0, value)
    }
    return values.filter { unit, value in
        visibility[unit] != .autoHide || value > 0 || values.count == 1
    }
}

private struct CanvasTextRenderer: View {
    let box: CampaignCanvasBox
    let block: CampaignCanvasTextBlock
    let shadow: CampaignCanvasShadow?
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    private var contentShadow: CampaignCanvasShadow? {
        box.hasVisibleSurface(isDark: isDark) ? nil : box.shadow
    }
    private var boxWithoutContentShadow: CampaignCanvasBox {
        guard contentShadow != nil else { return box }
        var value = box
        value.shadow = nil
        return value
    }
    var body: some View {
        ZStack {
            if contentShadow != nil {
                CanvasAlphaContentShadow(
                    shadow: contentShadow, isDark: isDark, includeContent: false
                ) {
                    CampaignCanvasBoxView(
                        box: boxWithoutContentShadow, isDark: isDark, clipsContent: false
                    ) {
                        CampaignCanvasTextView(block: block, isDark: isDark, onAction: onAction)
                    }
                }
            }
            CampaignCanvasBoxView(box: boxWithoutContentShadow, isDark: isDark, clipsContent: false)
            {
                CampaignCanvasTextView(
                    block: block, isDark: isDark, onAction: onAction, shadow: shadow)
            }
        }
    }
}

private struct CampaignCanvasTextView: View {
    let block: CampaignCanvasTextBlock
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    var colorOverride: UIColor? = nil
    var shadow: CampaignCanvasShadow? = nil
    var centerVertically = false
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        CanvasRichText(
            attributed: attributed,
            fillWidth: block.sizingMode == "fixed",
            maxLines: block.overflow == "ellipsis" ? block.maxLines : 0,
            overflow: block.overflow,
            textAlignment: block.textAlign.uiTextAlignment,
            centerVertically: centerVertically,
            onSpan: { span in
                onAction(
                    CampaignCanvasActionRequest(
                        actions: span.actions, elementId: canvasTextSpanElementID, label: span.text)
                )
            },
            spans: block.spans,
            drawingOutsets: glyphShadowOutsets
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: block.alignment)
    }

    private var glyphShadow: NSShadow? {
        guard let shadow,
            shadow.blur > 0 || shadow.spread > 0 || shadow.offsetX != 0 || shadow.offsetY != 0
        else {
            return nil
        }
        let value = NSShadow()
        value.shadowColor = UIColor(CampaignCanvasTheme.shared.color(shadow.color, isDark: isDark))
        value.shadowBlurRadius = glyphShadowBlurRadius
        value.shadowOffset = CGSize(width: shadow.offsetX, height: shadow.offsetY)
        return value
    }

    private var glyphShadowBlurRadius: CGFloat {
        guard let shadow else { return 0 }
        // Flutter converts the authored radius to sigma; Core Graphics' shadow
        // parameter behaves like a blur diameter, so feed it twice that sigma.
        let blurDiameter = shadow.blur > 0 ? 2 * (shadow.blur * 0.57735 + 0.5) : 0
        return max(0, blurDiameter + shadow.spread)
    }

    private var glyphShadowOutsets: UIEdgeInsets {
        guard let shadow,
            shadow.blur > 0 || shadow.spread > 0 || shadow.offsetX != 0 || shadow.offsetY != 0
        else {
            return .zero
        }
        let extent = max(shadow.blur * 2 + shadow.spread, glyphShadowBlurRadius * 2)
        return UIEdgeInsets(
            top: max(0, extent - shadow.offsetY),
            left: max(0, extent - shadow.offsetX),
            bottom: max(0, extent + shadow.offsetY),
            right: max(0, extent + shadow.offsetX)
        )
    }

    private var attributed: NSAttributedString {
        let first = block.spans.first
        let baseTypography = first?.typography ?? CampaignTypography()
        let baseColor =
            colorOverride ?? first?.color.map {
                UIColor(CampaignCanvasTheme.shared.color($0, isDark: isDark))
            } ?? .label
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = block.textAlign.uiTextAlignment
        if let lineHeight = baseTypography.lineHeight {
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
        }
        for (index, span) in block.spans.enumerated() {
            let typography = span.typography
            let color =
                colorOverride ?? span.color.map {
                    UIColor(CampaignCanvasTheme.shared.color($0, isDark: isDark))
                } ?? baseColor
            let font = SDKInstance.shared.font.resolve(
                size: Double(typography?.fontSize ?? baseTypography.fontSize ?? 16),
                weight: typography?.fontWeight ?? baseTypography.fontWeight ?? 400,
                italic: span.italic,
                fallbackFamily: typography?.fontFamily ?? baseTypography.fontFamily
            )
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            if centerVertically, let lineHeight = baseTypography.lineHeight {
                attributes[.baselineOffset] = max(0, lineHeight - font.lineHeight)
            }
            if let glyphShadow { attributes[.shadow] = glyphShadow }
            if let spacing = typography?.letterSpacing ?? baseTypography.letterSpacing, spacing != 0
            {
                attributes[.kern] = spacing
            }
            if let highlight = span.highlightColor {
                attributes[.backgroundColor] = UIColor(
                    CampaignCanvasTheme.shared.color(highlight, isDark: isDark))
            }
            switch span.decoration {
            case .underline: attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            case .lineThrough: attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            case .none: break
            }
            if let decorationColor = span.decorationColor {
                let value = UIColor(
                    CampaignCanvasTheme.shared.color(decorationColor, isDark: isDark))
                attributes[
                    span.decoration == .lineThrough ? .strikethroughColor : .underlineColor] = value
                attributes[.digiaDecorationColor] = value
            }
            if let thickness = span.decorationThickness {
                attributes[.digiaDecorationThickness] = thickness
            }
            if !span.actions.isEmpty {
                attributes[.link] = URL(string: "digia-canvas://span/\(index)")!
            }
            result.append(
                NSAttributedString(
                    string: interpolate(span.text, context: variables), attributes: attributes))
        }
        return result
    }
}

private struct CanvasRichText: UIViewRepresentable {
    let attributed: NSAttributedString
    let fillWidth: Bool
    let maxLines: Int
    let overflow: String
    let textAlignment: NSTextAlignment
    let centerVertically: Bool
    let onSpan: (CampaignCanvasTextSpan) -> Void
    var spans: [CampaignCanvasTextSpan] = []
    var drawingOutsets: UIEdgeInsets = .zero

    final class Coordinator: NSObject, UITextViewDelegate {
        var spans: [CampaignCanvasTextSpan] = []
        var onSpan: ((CampaignCanvasTextSpan) -> Void)?
        func textView(
            _ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard URL.scheme == "digia-canvas", let index = Int(URL.lastPathComponent),
                spans.indices.contains(index)
            else { return false }
            onSpan?(spans[index])
            return false
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> CanvasRichTextContainerView {
        let storage = NSTextStorage()
        let manager = DigiaDecorationLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let value = CanvasRichTextContainerView(textContainer: container)
        let textView = value.textView
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        value.setContentHuggingPriority(.required, for: .vertical)
        value.setContentHuggingPriority(fillWidth ? .defaultLow : .required, for: .horizontal)
        return value
    }
    func updateUIView(_ view: CanvasRichTextContainerView, context: Context) {
        context.coordinator.spans = spans
        context.coordinator.onSpan = onSpan
        let textView = view.textView
        view.centerVertically = centerVertically
        view.drawingOutsets = drawingOutsets
        textView.textStorage.setAttributedString(attributed)
        textView.textAlignment = textAlignment
        textView.textContainer.maximumNumberOfLines = max(0, maxLines)
        textView.textContainer.lineBreakMode =
            overflow == "ellipsis" ? .byTruncatingTail : .byClipping
        let hasActions = !spans.allSatisfy { $0.actions.isEmpty }
        textView.isSelectable = hasActions
        textView.isUserInteractionEnabled = hasActions
        textView.invalidateIntrinsicContentSize()
        view.invalidateIntrinsicContentSize()
    }
    static func dismantleUIView(_ view: CanvasRichTextContainerView, coordinator: Coordinator) {
        view.textView.delegate = nil
        view.textView.isSelectable = false
        coordinator.onSpan = nil
        coordinator.spans = []
    }
    @available(iOS 16, *)
    func sizeThatFits(
        _ proposal: ProposedViewSize, uiView: CanvasRichTextContainerView, context: Context
    ) -> CGSize? {
        let width = proposal.width ?? UIView.layoutFittingExpandedSize.width
        let fit = uiView.logicalSizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: fillWidth ? width : ceil(fit.width), height: centerVertically ? min(ceil(fit.height), proposal.height ?? .greatestFiniteMagnitude) : ceil(fit.height))
    }
}

private final class CanvasRichTextContainerView: UIView {
    let textView: UITextView
    var centerVertically = false
    var drawingOutsets: UIEdgeInsets = .zero {
        didSet {
            guard drawingOutsets != oldValue else { return }
            textView.textContainerInset = drawingOutsets
            setNeedsLayout()
            invalidateIntrinsicContentSize()
        }
    }

    init(textContainer: NSTextContainer) {
        textView = UITextView(frame: .zero, textContainer: textContainer)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = false
        textView.clipsToBounds = false
        textView.textContainerInset = .zero
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let verticalOverflow = centerVertically
            ? max(0, logicalSizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height - bounds.height) / 2
            : 0
        // Expand only the UIKit drawing surface. The matching text-container
        // insets keep glyph layout unchanged while making room for shadow bleed.
        textView.frame = CGRect(
            x: -drawingOutsets.left,
            y: -drawingOutsets.top - verticalOverflow,
            width: bounds.width + drawingOutsets.left + drawingOutsets.right,
            height: bounds.height + drawingOutsets.top + drawingOutsets.bottom + verticalOverflow * 2
        )
    }

    override var intrinsicContentSize: CGSize {
        logicalSize(from: textView.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        logicalSizeThatFits(size)
    }

    func logicalSizeThatFits(_ size: CGSize) -> CGSize {
        let expanded = CGSize(
            width: size.width.isFinite
                ? size.width + drawingOutsets.left + drawingOutsets.right : size.width,
            height: size.height.isFinite
                ? size.height + drawingOutsets.top + drawingOutsets.bottom : size.height
        )
        return logicalSize(from: textView.sizeThatFits(expanded))
    }

    private func logicalSize(from size: CGSize) -> CGSize {
        CGSize(
            width: size.width == UIView.noIntrinsicMetric
                ? size.width
                : max(0, size.width - drawingOutsets.left - drawingOutsets.right),
            height: size.height == UIView.noIntrinsicMetric
                ? size.height
                : max(0, size.height - drawingOutsets.top - drawingOutsets.bottom)
        )
    }
}

private struct CanvasImageRenderer: View {
    let box: CampaignCanvasBox
    let source: CampaignCanvasMediaSource
    let fit: String
    let positionX: CGFloat
    let positionY: CGFloat
    let scale: CGFloat
    let tint: CampaignColor?
    let isDark: Bool
    private var contentShadow: CampaignCanvasShadow? {
        box.hasVisibleSurface(isDark: isDark) ? nil : box.shadow
    }
    private var boxWithoutContentShadow: CampaignCanvasBox {
        guard contentShadow != nil else { return box }
        var value = box
        value.shadow = nil
        return value
    }
    var body: some View {
        CanvasAlphaContentShadow(shadow: contentShadow, isDark: isDark) {
            CampaignCanvasBoxView(box: boxWithoutContentShadow, isDark: isDark) {
                FocalCanvasImage(
                    source: source, isDark: isDark, fit: fit, x: positionX, y: positionY,
                    scale: scale, tint: tint, failureLabel: "Image")
            }
        }
    }
}

private struct CanvasAlphaContentShadow<Content: View>: View {
    let shadow: CampaignCanvasShadow?
    let isDark: Bool
    let includeContent: Bool
    let content: Content

    init(
        shadow: CampaignCanvasShadow?,
        isDark: Bool,
        includeContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.shadow = shadow
        self.isDark = isDark
        self.includeContent = includeContent
        self.content = content()
    }

    @ViewBuilder var body: some View {
        if let shadow,
            shadow.blur > 0 || shadow.spread > 0 || shadow.offsetX != 0 || shadow.offsetY != 0
        {
            if includeContent {
                shadowedContent(shadow)
            } else {
                ZStack {
                    shadowedContent(shadow)
                    content.blendMode(.destinationOut)
                }
                .compositingGroup()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else if includeContent {
            content
        }
    }

    private func shadowedContent(_ shadow: CampaignCanvasShadow) -> some View {
        content
            .compositingGroup()
            .shadow(
                color: CampaignCanvasTheme.shared.color(shadow.color, isDark: isDark),
                radius: shadow.nativeContentBlurRadius,
                x: shadow.offsetX,
                y: shadow.offsetY
            )
    }
}

extension CampaignCanvasBox {
    @MainActor
    fileprivate func hasVisibleSurface(isDark: Bool) -> Bool {
        let hasFill: Bool
        switch fill {
        case .solid(let color):
            hasFill =
                UIColor(CampaignCanvasTheme.shared.color(color, isDark: isDark)).cgColor.alpha > 0
        case .none:
            hasFill = false
        default:
            hasFill = true
        }
        let hasBorder =
            border.map {
                $0.width > 0
                    && UIColor(CampaignCanvasTheme.shared.color($0.color, isDark: isDark)).cgColor
                        .alpha > 0
            } ?? false
        return hasFill || hasBorder
    }
}

extension CampaignCanvasShadow {
    fileprivate var nativeContentBlurRadius: CGFloat {
        // SwiftUI consumes a Gaussian radius here. NSShadow's text path uses a
        // diameter-like value, but doubling this radius makes image halos too soft.
        let sigma = blur > 0 ? blur * 0.57735 + 0.5 : 0
        return max(0, sigma + spread)
    }
}

private struct CanvasButtonRenderer: View {
    let box: CampaignCanvasBox
    let label: CampaignCanvasTextBlock
    let cornerRadius: CampaignCanvasCornerRadius
    let style: CampaignCanvasButtonStyle
    let shadow: CampaignCanvasShadow?
    let isPrimary: Bool
    let isDestructive: Bool
    let applyDestructiveStyling: Bool
    let actions: [EngageAction]
    let confirm: CampaignCanvasConfirmDialog
    let isDark: Bool
    let onAction: (CampaignCanvasActionRequest) -> Void
    @State private var confirming = false
    private let danger = CampaignColor.literal("#FFD92D20")
    var body: some View {
        ZStack {
            if let shadow {
                CampaignCanvasShadowView(
                    shadow: shadow, cornerRadius: cornerRadius, isDark: isDark, outsideOnly: true)
            }
            CampaignCanvasBoxView(box: box, isDark: isDark) {
                Group {
                    if actions.isEmpty {
                        buttonContent
                    } else {
                        Button {
                            if isDestructive { confirming = true } else { emit() }
                        } label: {
                            buttonContent
                        }
                        .buttonStyle(CanvasPressedButtonStyle())
                    }
                }
                .clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
                .overlay(
                    outline.map {
                        CampaignCanvasRoundedShape(radius: cornerRadius).strokeBorder(
                            CampaignCanvasTheme.shared.color($0.color, isDark: isDark),
                            lineWidth: $0.width)
                    })
            }
        }
        .alert(confirm.title ?? "", isPresented: $confirming) {
            Button(confirm.cancelLabel, role: .cancel) {}
            Button(confirm.confirmLabel, role: isDestructive ? .destructive : nil) { emit() }
        } message: {
            if let message = confirm.message { Text(message) }
        }
    }
    private var buttonContent: some View {
        ZStack {
            CampaignCanvasPaintView(paint: effectiveFill, isDark: isDark)
            CampaignCanvasTextView(
                block: label, isDark: isDark, onAction: onAction,
                colorOverride: destructiveColor, centerVertically: true)
        }.contentShape(CampaignCanvasRoundedShape(radius: cornerRadius))
    }
    private var effectiveFill: CampaignCanvasPaint {
        isDestructive && applyDestructiveStyling && isFilled ? .solid(danger) : style.fill
    }
    private var isFilled: Bool { if case .fill = style { true } else { false } }
    private var destructiveColor: UIColor? {
        guard isDestructive && applyDestructiveStyling else { return nil }
        return UIColor(
            isFilled ? Color.white : CampaignCanvasTheme.shared.color(danger, isDark: isDark))
    }
    private var outline: CampaignCanvasBorder? {
        if case .outline(_, let outline) = style { outline } else { nil }
    }
    private func emit() {
        onAction(
            CampaignCanvasActionRequest(
                actions: actions, elementId: isPrimary ? "cta_primary" : "cta_secondary",
                label: label.plainText, isPrimary: isPrimary))
    }
}

private struct CanvasPressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct CanvasProgressRenderer: View {
    let box: CampaignCanvasBox
    let valueMode: CampaignCanvasProgressValueMode
    let percent: String
    let rangeStart: String
    let rangeCurrent: String
    let rangeEnd: String
    let indicator: CampaignCanvasPaint
    let track: CampaignCanvasPaint
    let cornerRadius: CampaignCanvasCornerRadius
    let animateOnAppear: CampaignCanvasAppearAnimation
    let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    @State private var displayed: CGFloat = 0
    @State private var appeared = false
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
                    CampaignCanvasPaintView(paint: indicator, isDark: isDark).frame(
                        width: geometry.size.width * displayed)
                }.clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
            }
        }
        .onAppear {
            if animateOnAppear.enabled {
                withAnimation(.easeOut(duration: Double(animateOnAppear.durationMs) / 1000)) {
                    displayed = target
                }
            } else {
                displayed = target
            }
            appeared = true
        }
        .onChange(of: target) { value in
            if appeared {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { displayed = value }
            }
        }
    }
}

private struct CanvasLottieRenderer: View {
    let box: CampaignCanvasBox
    let source: CampaignCanvasMediaSource
    let autoplay: Bool
    let loop: Bool
    let fit: String
    let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    private var boxWithoutShadow: CampaignCanvasBox {
        var value = box
        value.shadow = nil
        return value
    }
    var body: some View {
        ZStack {
            if let shadow = box.shadow {
                CampaignCanvasShadowView(
                    shadow: shadow,
                    cornerRadius: box.cornerRadius,
                    isDark: isDark,
                    outsideOnly: true
                )
            }
            CampaignCanvasBoxView(box: boxWithoutShadow, isDark: isDark) {
                let raw = CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark)
                let resolved = interpolate(raw, context: variables)
                if resolved.isEmpty {
                    CanvasPlaceholder(label: "Lottie")
                } else if let url = URL(string: resolved) {
                    CanvasRemoteLottie(
                        url: url, placeholder: source.placeholder, autoplay: autoplay, loop: loop,
                        fit: fit
                    )
                    .id(resolved)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    CanvasPlaceholder(label: "Lottie")
                }
            }
        }
    }
}

private struct CanvasRemoteLottie: View {
    let url: URL
    let placeholder: ImagePlaceholder?
    let autoplay: Bool
    let loop: Bool
    let fit: String
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
                if url.pathExtension.lowercased() == "lottie" {
                    return try await DotLottieFile.loadedFrom(url: url).animationSource
                }
                guard let source = await LottieAnimation.loadedFrom(url: url)?.animationSource
                else {
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
    let failed: Bool
    let placeholder: ImagePlaceholder?
    let fit: String
    var body: some View {
        if failed {
            CanvasPlaceholder(label: "Lottie")
        } else {
            BlurHashPlaceholderView(
                placeholder: placeholder, contentMode: fit == "contain" ? .fit : .fill)
        }
    }
}

private struct CanvasVideoRenderer: View {
    let box: CampaignCanvasBox
    let source: CampaignCanvasMediaSource
    let autoplay: Bool
    let loop: Bool
    let muted: Bool
    let showControls: Bool
    let fit: String
    let isDark: Bool
    @Environment(\.digiaVariables) private var variables
    @Environment(\.canvasVideoUsesStoryPlayback) private var usesStoryPlayback
    @State private var player: AVPlayer?
    @State private var observer: NSObjectProtocol?
    private var url: String {
        interpolate(CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark), context: variables)
    }
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            if !url.isEmpty {
                if usesStoryPlayback {
                    CanvasStoryCachedMedia(
                        url: url,
                        isVideo: true,
                        contentMode: fit == "contain" ? .fit : .fill,
                        autoplay: autoplay,
                        loop: loop,
                        muted: muted,
                        showControls: showControls
                    )
                    .id(url)
                } else {
                    ZStack {
                        Color.black
                        if let player {
                            CanvasPlayerController(
                                player: player, controls: showControls,
                                gravity: fit == "contain" ? .resizeAspect : .resizeAspectFill)
                        }
                    }
                }
            }
        }
        .onAppear { setup() }
        .onChange(of: url) { _ in
            teardown()
            setup()
        }
        .onDisappear { teardown() }
    }
    private func setup() {
        guard !usesStoryPlayback else { return }
        guard player == nil, let parsed = URL(string: url), !url.isEmpty else { return }
        let item = AVPlayerItem(url: parsed)
        let value = AVPlayer(playerItem: item)
        value.isMuted = muted
        player = value
        if loop {
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
            ) { _ in
                value.seek(to: .zero)
                value.play()
            }
        }
        if autoplay { value.play() }
    }
    private func teardown() {
        player?.pause()
        player = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

struct CanvasPlayerController: UIViewControllerRepresentable {
    let player: AVPlayer
    let controls: Bool
    let gravity: AVLayerVideoGravity
    var onReadyForDisplay: () -> Void = {}

    final class Coordinator {
        var readyObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let value = AVPlayerViewController()
        value.player = player
        value.showsPlaybackControls = controls
        value.videoGravity = gravity
        context.coordinator.readyObservation = value.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { controller, _ in
            guard controller.isReadyForDisplay else { return }
            Task { @MainActor in onReadyForDisplay() }
        }
        return value
    }
    func updateUIViewController(_ value: AVPlayerViewController, context: Context) {
        value.player = player
        value.showsPlaybackControls = controls
        value.videoGravity = gravity
    }

    static func dismantleUIViewController(_ value: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.readyObservation?.invalidate()
        coordinator.readyObservation = nil
        value.player = nil
    }
}

private struct CanvasContainerRenderer: View {
    let fill: CampaignCanvasPaint
    let cornerRadius: CampaignCanvasCornerRadius
    let border: CampaignCanvasBorder?
    let shadow: CampaignCanvasShadow?
    let isDark: Bool
    var body: some View {
        ZStack {
            if let shadow {
                CampaignCanvasShadowView(shadow: shadow, cornerRadius: cornerRadius, isDark: isDark)
            }
            CampaignCanvasPaintView(paint: fill, isDark: isDark)
                .clipShape(CampaignCanvasRoundedShape(radius: cornerRadius))
                .overlay(
                    border.map {
                        CampaignCanvasRoundedShape(radius: cornerRadius).strokeBorder(
                            CampaignCanvasTheme.shared.color($0.color, isDark: isDark),
                            lineWidth: $0.width)
                    })
        }
    }
}

private struct CanvasDividerRenderer: View {
    let box: CampaignCanvasBox
    let axis: CampaignCanvasDividerAxis
    let pattern: CampaignCanvasDividerPattern
    let strokeCap: CampaignCanvasStrokeCap
    let inset: CGFloat
    let dashPattern: [CGFloat]
    let color: CampaignColor
    let isDark: Bool
    var body: some View {
        CampaignCanvasBoxView(box: box, isDark: isDark) {
            Canvas { context, size in
                let horizontal = axis == .horizontal
                var path = Path()
                path.move(
                    to: horizontal
                        ? CGPoint(x: inset, y: size.height / 2)
                        : CGPoint(x: size.width / 2, y: inset))
                path.addLine(
                    to: horizontal
                        ? CGPoint(x: size.width - inset, y: size.height / 2)
                        : CGPoint(x: size.width / 2, y: size.height - inset))
                let thickness = horizontal ? size.height : size.width
                let dash: [CGFloat] =
                    pattern == .solid
                    ? []
                    : (pattern == .dotted
                        ? [0, max(thickness, dashPattern.dropFirst().first ?? 4)] : dashPattern)
                context.stroke(
                    path, with: .color(CampaignCanvasTheme.shared.color(color, isDark: isDark)),
                    style: StrokeStyle(lineWidth: thickness, lineCap: strokeCap.lineCap, dash: dash)
                )
            }
        }
    }
}

private struct CampaignCanvasBoxView<Content: View>: View {
    let box: CampaignCanvasBox
    let isDark: Bool
    var clipsContent = true
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            if let shadow = box.shadow {
                CampaignCanvasShadowView(
                    shadow: shadow, cornerRadius: box.cornerRadius, isDark: isDark)
            }
            Group {
                if clipsContent {
                    contentLayer.clipShape(CampaignCanvasRoundedShape(radius: box.cornerRadius))
                } else {
                    contentLayer
                }
            }
            .overlay(
                box.border.map {
                    CampaignCanvasRoundedShape(radius: box.cornerRadius).strokeBorder(
                        CampaignCanvasTheme.shared.color($0.color, isDark: isDark),
                        lineWidth: $0.width)
                })
        }
    }
    private var contentLayer: some View {
        ZStack {
            CampaignCanvasPaintView(paint: box.fill, isDark: isDark)
                .clipShape(CampaignCanvasRoundedShape(radius: box.cornerRadius))
            content().padding(
                EdgeInsets(
                    top: box.padding.top, leading: box.padding.left, bottom: box.padding.bottom,
                    trailing: box.padding.right))
        }
    }
}

private struct CampaignCanvasShadowView: View {
    let shadow: CampaignCanvasShadow
    let cornerRadius: CampaignCanvasCornerRadius
    let isDark: Bool
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

struct CampaignCanvasBackgroundView: View {
    let paint: CampaignCanvasPaint
    @ObservedObject private var theme = CampaignCanvasTheme.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        CampaignCanvasPaintView(paint: paint, isDark: theme.isDark(colorScheme))
    }
}

struct CampaignCanvasPaintView: View {
    let paint: CampaignCanvasPaint
    let isDark: Bool
    var body: some View {
        switch paint {
        case .solid(let color): CampaignCanvasTheme.shared.color(color, isDark: isDark)
        case .gradient(let type, let angle, let x, let y, let radius, let start, let end, let stops):
            CampaignCanvasGradientView(
                type: type, angle: angle, centerX: x, centerY: y, radius: radius, start: start,
                end: end, stops: stops, isDark: isDark)
        case .image(let source, let x, let y, let scale):
            FocalCanvasImage(source: source, isDark: isDark, fit: "cover", x: x, y: y, scale: scale)
        case .none: Color.clear
        }
    }
}

enum GuideCanvasPointerDirection: Equatable {
    case up, down, left, right
}

private struct CampaignCanvasGradientView: View {
    let type: CampaignCanvasGradientType
    let angle: CGFloat
    let centerX: CGFloat
    let centerY: CGFloat
    let radius: CGFloat
    let start: CGFloat
    let end: CGFloat
    let stops: [CampaignCanvasGradientStop]
    let isDark: Bool
    var body: some View {
        if stops.isEmpty {
            Color.clear
        } else if stops.count == 1 {
            CampaignCanvasTheme.shared.color(stops[0].color, isDark: isDark)
        } else {
            GeometryReader { geometry in
                switch type {
                case .linear:
                    Canvas { context, size in
                        let radians = angle * .pi / 180
                        let direction = CGVector(dx: sin(radians), dy: -cos(radians))
                        let extent =
                            abs(direction.dx) * size.width + abs(direction.dy) * size.height
                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        let delta = CGPoint(
                            x: direction.dx * extent / 2, y: direction.dy * extent / 2)
                        context.fill(
                            Path(CGRect(origin: .zero, size: size)),
                            with: .linearGradient(
                                Gradient(stops: gradientStops),
                                startPoint: CGPoint(x: center.x - delta.x, y: center.y - delta.y),
                                endPoint: CGPoint(x: center.x + delta.x, y: center.y + delta.y)))
                    }
                case .radial:
                    RadialGradient(
                        gradient: Gradient(stops: gradientStops),
                        center: UnitPoint(x: centerX, y: centerY), startRadius: 0,
                        endRadius: min(geometry.size.width, geometry.size.height) * radius)
                case .sweep:
                    AngularGradient(
                        gradient: Gradient(stops: gradientStops),
                        center: UnitPoint(x: centerX, y: centerY), startAngle: .degrees(start - 90),
                        endAngle: .degrees(end - 90))
                }
            }
        }
    }
    private var gradientStops: [Gradient.Stop] {
        stops.map {
            .init(
                color: CampaignCanvasTheme.shared.color($0.color, isDark: isDark),
                location: $0.offset)
        }
    }
}

private struct FocalCanvasImage: View {
    let source: CampaignCanvasMediaSource
    let isDark: Bool
    let fit: String
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat
    var tint: CampaignColor? = nil
    var failureLabel: String? = nil
    @Environment(\.digiaVariables) private var variables
    @State private var failedURL: String?
    var body: some View {
        let raw = CampaignCanvasTheme.shared.mediaURL(source, isDark: isDark)
        let resolved = interpolate(raw, context: variables)
        if resolved.isEmpty || failedURL == resolved {
            if let failureLabel { CanvasPlaceholder(label: failureLabel) }
        } else if URL(string: resolved) == nil {
            if let failureLabel { CanvasPlaceholder(label: failureLabel) }
        } else {
            GeometryReader { geometry in
                WebImage(url: URL(string: resolved)) { image in
                    image.resizable().renderingMode(tint == nil ? .original : .template)
                } placeholder: {
                    BlurHashPlaceholderView(
                        placeholder: source.placeholder,
                        contentMode: fit == "contain" ? .fit : .fill)
                }
                .onFailure { _ in failedURL = resolved }
                .modifier(CanvasImageFit(fit: fit))
                .foregroundStyle(
                    tint.map { CampaignCanvasTheme.shared.color($0, isDark: isDark) } ?? .clear
                )
                .frame(
                    width: geometry.size.width, height: geometry.size.height,
                    alignment: focalAlignment(x: x, y: y)
                )
                .scaleEffect(
                    max(0.1, scale), anchor: UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                )
                .clipped()
            }
            .onChange(of: resolved) { _ in failedURL = nil }
        }
    }
}

private struct CanvasImageFit: ViewModifier {
    let fit: String
    @ViewBuilder func body(content: Content) -> some View {
        switch fit {
        case "contain": content.scaledToFit()
        case "fill": content
        default: content.scaledToFill()
        }
    }
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
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRight),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct CanvasChildBoundsModifier: ViewModifier {
    let clips: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if clips { content.clipped() } else { content }
    }
}

private struct CanvasPlaceholder: View {
    let label: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color(hex: "#F1F1F5") ?? Color(.systemGray6))
            Text(label).font(.system(size: 11)).foregroundStyle(Color(hex: "#9A9AAD") ?? .secondary)
        }
    }
}

extension CampaignCanvasHorizontalAlign {
    fileprivate var uiTextAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
extension CampaignCanvasTextBlock {
    fileprivate var alignment: Alignment {
        let horizontal: HorizontalAlignment =
            horizontalAlign == .left ? .leading : (horizontalAlign == .right ? .trailing : .center)
        let vertical: VerticalAlignment =
            verticalAlign == .top ? .top : (verticalAlign == .bottom ? .bottom : .center)
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}
extension CampaignCanvasStrokeCap {
    fileprivate var lineCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}
extension String {
    fileprivate var uiContentMode: UIView.ContentMode {
        switch self {
        case "contain": .scaleAspectFit
        case "fill": .scaleToFill
        default: .scaleAspectFill
        }
    }
}
private func focalAlignment(x: CGFloat, y: CGFloat) -> Alignment {
    Alignment(
        horizontal: x < 0.34 ? .leading : (x > 0.66 ? .trailing : .center),
        vertical: y < 0.34 ? .top : (y > 0.66 ? .bottom : .center))
}
