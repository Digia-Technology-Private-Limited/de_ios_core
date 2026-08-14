import Foundation

let defaultCampaignCanvasDesignWidth: CGFloat = 360

struct CampaignColor: Equatable, Sendable {
    let lightHex: String
    let darkHex: String
    static func literal(_ hex: String) -> CampaignColor { .init(lightHex: hex, darkHex: hex) }
}

struct CampaignTypography: Equatable, Sendable {
    var fontFamily: String?
    var fontSize: CGFloat?
    var fontWeight: Int?
    var lineHeight: CGFloat?
    var letterSpacing: CGFloat?
}

struct CampaignCanvasMediaSource: Equatable {
    let url: String
    let darkUrl: String?
    let placeholder: ImagePlaceholder?
}

enum CampaignCanvasGradientType: Equatable { case linear, radial, sweep }
struct CampaignCanvasGradientStop: Equatable { let color: CampaignColor; let offset: CGFloat }

enum CampaignCanvasPaint: Equatable {
    case solid(CampaignColor)
    case gradient(
        type: CampaignCanvasGradientType,
        angleDegrees: CGFloat,
        centerX: CGFloat,
        centerY: CGFloat,
        radius: CGFloat,
        startAngleDegrees: CGFloat,
        endAngleDegrees: CGFloat,
        stops: [CampaignCanvasGradientStop]
    )
    case image(source: CampaignCanvasMediaSource, positionX: CGFloat, positionY: CGFloat, scale: CGFloat)
    case none
}

struct CampaignCanvasEdgeInsets: Equatable {
    var top: CGFloat = 0; var right: CGFloat = 0; var bottom: CGFloat = 0; var left: CGFloat = 0
}

struct CampaignCanvasCornerRadius: Equatable {
    var topLeft: CGFloat = 0; var topRight: CGFloat = 0
    var bottomRight: CGFloat = 0; var bottomLeft: CGFloat = 0
    static let zero = CampaignCanvasCornerRadius()
}

struct CampaignCanvasBorder: Equatable { let color: CampaignColor; let width: CGFloat }
struct CampaignCanvasShadow: Equatable {
    let color: CampaignColor; let blur: CGFloat; let spread: CGFloat
    let offsetX: CGFloat; let offsetY: CGFloat
}

struct CampaignCanvasBox: Equatable {
    var fill: CampaignCanvasPaint = .none
    var padding = CampaignCanvasEdgeInsets()
    var cornerRadius = CampaignCanvasCornerRadius.zero
    var border: CampaignCanvasBorder?
    var shadow: CampaignCanvasShadow?
    static let none = CampaignCanvasBox()
}

enum CampaignCanvasHorizontalAlign: Equatable { case left, center, right }
enum CampaignCanvasVerticalAlign: Equatable { case top, center, bottom }
enum CampaignCanvasTextDecoration: Equatable { case none, underline, lineThrough }

struct CampaignCanvasTextSpan: Equatable {
    let text: String
    let typography: CampaignTypography?
    let color: CampaignColor?
    let highlightColor: CampaignColor?
    let italic: Bool
    let decoration: CampaignCanvasTextDecoration
    let decorationColor: CampaignColor?
    let decorationThickness: CGFloat?
    let actions: [EngageAction]
}

struct CampaignCanvasTextBlock: Equatable {
    let horizontalAlign: CampaignCanvasHorizontalAlign
    let textAlign: CampaignCanvasHorizontalAlign
    let verticalAlign: CampaignCanvasVerticalAlign
    let maxLines: Int
    let overflow: String
    let sizingMode: String
    var spans: [CampaignCanvasTextSpan]
    var plainText: String { spans.map(\.text).joined() }
}

enum CampaignCanvasButtonStyle: Equatable {
    case fill(fill: CampaignCanvasPaint)
    case outline(fill: CampaignCanvasPaint, outline: CampaignCanvasBorder)
    case text
    var fill: CampaignCanvasPaint {
        switch self { case .fill(let fill), .outline(let fill, _): fill; case .text: .none }
    }
}

struct CampaignCanvasConfirmDialog: Equatable {
    var title: String?; var message: String?
    var confirmLabel = "Yes"; var cancelLabel = "Cancel"
    var titleFontWeight = 700; var messageFontWeight = 400; var buttonFontWeight = 600
}

enum CampaignCanvasProgressValueMode: Equatable { case percent, range }
struct CampaignCanvasAppearAnimation: Equatable { let enabled: Bool; let durationMs: Int }
enum CampaignCanvasDividerAxis: Equatable { case horizontal, vertical }
enum CampaignCanvasDividerPattern: Equatable { case solid, dashed, dotted }
enum CampaignCanvasStrokeCap: Equatable { case butt, round, square }

enum CampaignCanvasWidget: Equatable {
    case text(box: CampaignCanvasBox, block: CampaignCanvasTextBlock, shadow: CampaignCanvasShadow?)
    case image(
        box: CampaignCanvasBox, source: CampaignCanvasMediaSource, fit: String,
        positionX: CGFloat, positionY: CGFloat, scale: CGFloat, tintColor: CampaignColor?
    )
    case button(
        box: CampaignCanvasBox, label: CampaignCanvasTextBlock,
        cornerRadius: CampaignCanvasCornerRadius, style: CampaignCanvasButtonStyle,
        shadow: CampaignCanvasShadow?,
        isPrimary: Bool, isDestructive: Bool, applyDestructiveStyling: Bool,
        actions: [EngageAction], confirm: CampaignCanvasConfirmDialog
    )
    case progress(
        box: CampaignCanvasBox, valueMode: CampaignCanvasProgressValueMode,
        percent: String, rangeStart: String, rangeCurrent: String, rangeEnd: String,
        indicator: CampaignCanvasPaint, track: CampaignCanvasPaint,
        cornerRadius: CampaignCanvasCornerRadius, animateOnAppear: CampaignCanvasAppearAnimation
    )
    case lottie(box: CampaignCanvasBox, source: CampaignCanvasMediaSource, autoplay: Bool, loop: Bool, fit: String)
    case video(box: CampaignCanvasBox, source: CampaignCanvasMediaSource, autoplay: Bool, loop: Bool, muted: Bool, showControls: Bool, fit: String)
    case container(fill: CampaignCanvasPaint, cornerRadius: CampaignCanvasCornerRadius, border: CampaignCanvasBorder?, shadow: CampaignCanvasShadow?)
    case divider(box: CampaignCanvasBox, axis: CampaignCanvasDividerAxis, pattern: CampaignCanvasDividerPattern, strokeCap: CampaignCanvasStrokeCap, inset: CGFloat, dashPattern: [CGFloat], color: CampaignColor)

    var box: CampaignCanvasBox {
        switch self {
        case .text(let box, _, _), .image(let box, _, _, _, _, _, _),
             .button(let box, _, _, _, _, _, _, _, _, _),
             .progress(let box, _, _, _, _, _, _, _, _, _),
             .lottie(let box, _, _, _, _), .video(let box, _, _, _, _, _, _),
             .divider(let box, _, _, _, _, _, _): box
        case .container: .none
        }
    }
}

struct CampaignCanvasRect: Equatable { let x: CGFloat; let y: CGFloat; let width: CGFloat; let height: CGFloat }
enum CampaignCanvasChild: Equatable, Identifiable {
    case widget(id: String, rect: CampaignCanvasRect, widget: CampaignCanvasWidget)
    case tapRegion(id: String, rect: CampaignCanvasRect, actions: [EngageAction])
    var id: String { switch self { case .widget(let id, _, _), .tapRegion(let id, _, _): id } }
    var rect: CampaignCanvasRect { switch self { case .widget(_, let rect, _), .tapRegion(_, let rect, _): rect } }
    var clipsToAuthoredRect: Bool {
        guard case .widget(_, _, let widget) = self else { return true }
        if case .container = widget { return false }
        if widget.box.shadow != nil { return false }
        if case .text(_, _, let shadow) = widget, shadow != nil { return false }
        if case .button(_, _, _, _, let shadow, _, _, _, _, _) = widget { return shadow == nil }
        return true
    }
    var isHitTestable: Bool {
        switch self {
        case .tapRegion: true
        case .widget(_, _, .text(_, let block, _)):
            block.spans.contains { !$0.actions.isEmpty }
        case .widget(_, _, .button(_, let label, _, _, _, _, _, _, let actions, _)):
            !actions.isEmpty || label.spans.contains { !$0.actions.isEmpty }
        case .widget(_, _, .video(_, _, _, _, _, let showControls, _)):
            showControls
        default: false
        }
    }
}

struct CampaignCanvas: Equatable {
    let version: Int; let width: CGFloat; let height: CGFloat
    let background: CampaignCanvasPaint; let children: [CampaignCanvasChild]
}

struct CampaignCanvasActionRequest: Equatable {
    let actions: [EngageAction]; let elementId: String
    var label: String? = nil; var isPrimary = false
}
