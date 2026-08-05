@_implementationOnly import SDWebImageSwiftUI
import SwiftUI

private let maxFloatingCanvasUpscale: CGFloat = 1.15

/// Renders the dashboard's logical-pixel canvas as one authored stage. Geometry,
/// typography, decoration and media are measured at their authored values and
/// receive one uniform runtime transform, which prevents individual children
/// from being squeezed by SwiftUI's parent constraints.
struct CampaignCanvasView: View {
    let canvas: NudgeCanvas
    let surface: NudgeSurface
    let designWidth: CGFloat
    /// Full runtime viewport width drives logical-pixel scale. `availableSize`
    /// may be narrower (for example, a dialog's required side margins) and is
    /// used only as the fit boundary.
    var runtimeViewportWidth: CGFloat? = nil
    let availableSize: CGSize
    let onDismiss: () -> Void

    private var designScale: CGFloat {
        let base = (runtimeViewportWidth ?? availableSize.width) / max(designWidth, 1)
        return surface.isBottomSheet ? base : min(base, maxFloatingCanvasUpscale)
    }

    private var scale: CGFloat {
        let naturalWidth = max(canvas.width * designScale, 1)
        let naturalHeight = max(canvas.height * designScale, 1)
        return designScale * min(
            1,
            availableSize.width / naturalWidth,
            availableSize.height / naturalHeight
        )
    }

    var body: some View {
        CampaignCanvasStage(
            canvas: canvas,
            surface: surface,
            authoredCornerRadius: surface.cornerRadius / max(designScale, 0.001),
            onDismiss: onDismiss
        )
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(
            width: canvas.width * scale,
            height: canvas.height * scale,
            alignment: .topLeading
        )
    }
}

private struct CampaignCanvasStage: View {
    let canvas: NudgeCanvas
    let surface: NudgeSurface
    let authoredCornerRadius: CGFloat
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            CanvasBackgroundView(background: canvas.background)

            ForEach(canvas.children, id: \.id) { child in
                let rect = child.rect
                CanvasChildView(child: child, onDismiss: onDismiss)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    // Media must remain inside its authored rectangle, while a
                    // container's configured drop shadow is allowed to extend
                    // beyond that rectangle (the stage still clips at the surface).
                    .modifier(CanvasChildBoundsModifier(clips: child.clipsToAuthoredRect))
                    .offset(x: rect.x, y: rect.y)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: max(0, authoredCornerRadius)))
    }
}

private struct CanvasChildView: View {
    let child: NudgeCanvasChild
    let onDismiss: () -> Void
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        switch child {
        case .widget(_, _, let node):
            if case .canvasContainer(let container) = node {
                CanvasContainerView(node: container)
            } else {
                NudgeCanvasNodeContent(node: node, onDismiss: onDismiss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: node))
                    .canvasBox(node.box)
                    .clipped()
            }
        case .tapRegion(let id, _, let actions):
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    SDKInstance.shared.emitNudgeClick(
                        elementId: id,
                        ctaLabel: nil,
                        actionType: nil,
                        actionUrl: nil,
                        ctaRole: "secondary"
                    )
                    Task {
                        await SDKInstance.shared.executeActionFlow(
                            actions,
                            variables: variables,
                            localActionExecutor: LocalActionExecutor(dismiss: onDismiss)
                        )
                    }
                }
        }
    }

    private func alignment(for node: NudgeNode) -> Alignment {
        guard case .text(let text) = node else { return .topLeading }
        switch text.verticalAlignment {
        case "center": return .center
        case "bottom": return .bottom
        default: return .top
        }
    }
}

private struct CanvasBackgroundView: View {
    let background: NudgeCanvasBackground
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        switch background {
        case .color(let color):
            color
        case .image(let url, let x, let y, let scale):
            let resolved = interpolate(url, context: variables)
            if resolved.isEmpty {
                Color.white
            } else {
                FocalCanvasImage(url: resolved, x: x, y: y, scale: scale)
            }
        case .gradient(let angle, let stops):
            CanvasLinearGradient(angleDegrees: angle, stops: stops)
        }
    }
}

private struct FocalCanvasImage: View {
    let url: String
    let x: CGFloat
    let y: CGFloat
    let scale: CGFloat

    var body: some View {
        GeometryReader { geometry in
            WebImage(url: URL(string: url)) { $0.resizable() } placeholder: {
                Color.clear
            }
                .scaledToFill()
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: focalAlignment(x: x, y: y)
                )
                .scaleEffect(
                    max(0.1, scale),
                    anchor: UnitPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                )
                .clipped()
        }
    }
}

private struct CanvasLinearGradient: View {
    let angleDegrees: CGFloat
    let stops: [NudgeCanvasGradientStop]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let radians = angleDegrees * .pi / 180
                let direction = CGVector(dx: sin(radians), dy: -cos(radians))
                let extent = abs(direction.dx) * size.width + abs(direction.dy) * size.height
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let delta = CGPoint(x: direction.dx * extent / 2, y: direction.dy * extent / 2)
                let colors = stops.isEmpty
                    ? [NudgeCanvasGradientStop(color: .white, offset: 0),
                       NudgeCanvasGradientStop(color: .white, offset: 1)]
                    : stops.sorted { $0.offset < $1.offset }
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .linearGradient(
                        Gradient(stops: colors.map { .init(color: $0.color, location: $0.offset) }),
                        startPoint: CGPoint(x: center.x - delta.x, y: center.y - delta.y),
                        endPoint: CGPoint(x: center.x + delta.x, y: center.y + delta.y)
                    )
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct CanvasContainerView: View {
    let node: NudgeCanvasContainer
    @Environment(\.digiaVariables) private var variables

    var body: some View {
        ZStack {
            fill
            if node.fillType == "image", !node.imageURL.isEmpty {
                FocalCanvasImage(
                    url: interpolate(node.imageURL, context: variables),
                    x: node.imagePositionX,
                    y: node.imagePositionY,
                    scale: node.imageScale
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: node.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: node.cornerRadius)
                .strokeBorder(node.borderColor, lineWidth: node.borderWidth)
        )
        .shadow(
            color: node.shadowColor.opacity(node.shadowOpacity),
            radius: node.shadowBlur / 2,
            x: node.shadowOffsetX,
            y: node.shadowOffsetY
        )
    }

    @ViewBuilder
    private var fill: some View {
        switch node.fillType {
        case "gradient":
            CanvasLinearGradient(
                angleDegrees: node.gradientAngle,
                stops: [
                    .init(color: node.gradientStartColor, offset: 0),
                    .init(color: node.gradientEndColor, offset: 1),
                ]
            )
        case "solid": node.color
        default: Color.clear
        }
    }
}

private struct CanvasChildBoundsModifier: ViewModifier {
    let clips: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if clips {
            content.clipped()
        } else {
            content
        }
    }
}

private extension NudgeCanvasChild {
    var clipsToAuthoredRect: Bool {
        if case .widget(_, _, .canvasContainer(_)) = self {
            return false
        }
        return true
    }
}

private struct CanvasBoxModifier: ViewModifier {
    let box: NudgeBox

    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(
                top: box.paddingTop,
                leading: box.paddingLeft,
                bottom: box.paddingBottom,
                trailing: box.paddingRight
            ))
            .background(
                box.background.map { AnyView(
                    RoundedRectangle(cornerRadius: box.borderRadius).fill($0)
                ) } ?? AnyView(EmptyView())
            )
            .clipShape(RoundedRectangle(cornerRadius: max(0, box.borderRadius)))
            .overlay(
                RoundedRectangle(cornerRadius: max(0, box.borderRadius))
                    .stroke(box.borderColor ?? .clear, lineWidth: box.borderWidth)
            )
    }
}

private extension View {
    func canvasBox(_ box: NudgeBox) -> some View { modifier(CanvasBoxModifier(box: box)) }
}

private func focalAlignment(x: CGFloat, y: CGFloat) -> Alignment {
    let horizontal: HorizontalAlignment = x < 0.34 ? .leading : (x > 0.66 ? .trailing : .center)
    let vertical: VerticalAlignment = y < 0.34 ? .top : (y > 0.66 ? .bottom : .center)
    return Alignment(horizontal: horizontal, vertical: vertical)
}
