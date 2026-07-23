import SwiftUI

// MARK: - Box decoration

struct NudgeBox: Equatable {
    var fillWidth: Bool = false
    var fixedWidth: CGFloat? = nil
    var fixedHeight: CGFloat? = nil
    var background: Color? = nil
    var paddingLeft: CGFloat = 0
    var paddingTop: CGFloat = 0
    var paddingRight: CGFloat = 0
    var paddingBottom: CGFloat = 0
    var marginLeft: CGFloat = 0
    var marginTop: CGFloat = 0
    var marginRight: CGFloat = 0
    var marginBottom: CGFloat = 0
    var borderRadius: CGFloat = 0
    var borderColor: Color? = nil
    var borderWidth: CGFloat = 0
    var selfAlign: NudgeSelfAlign? = nil

    static let none = NudgeBox()

    func withoutFixedHeight() -> NudgeBox {
        var copy = self; copy.fixedHeight = nil; return copy
    }
}

enum NudgeSelfAlign          { case start, center, end }
enum NudgeButtonVariant      { case fill, outline, text, elevated }

enum NudgeContentFit { case cover, contain, fill }
enum NudgeCrossAxisAlignment { case start, center, end }
enum NudgeMainAxisAlignment  { case start, center, end, spaceBetween, spaceAround, spaceEvenly }

// MARK: - Node hierarchy

enum NudgeNode: Equatable {
    case text(NudgeText)
    case image(NudgeImage)
    case button(NudgeButton)
    case gap(NudgeGap)
    case divider(NudgeDivider)
    case lottie(NudgeLottie)
    case carousel(NudgeCarousel)
    case video(NudgeVideo)

    var box: NudgeBox {
        switch self {
        case .text(let n):    return n.box
        case .image(let n):   return n.box
        case .button(let n):  return n.box
        case .gap(let n):     return n.box
        case .divider(let n): return n.box
        case .lottie(let n):  return n.box
        case .carousel(let n): return n.box
        case .video(let n):   return n.box
        }
    }
}

/// One styled run of a Text widget's rich overlay. Every style field is `nil`
/// when the run inherits the Text widget's base style for it (the dashboard's
/// `span.style` contract). `highlightColor` paints behind the text; `lineHeight`
/// is a unitless multiplier.
/// Per-run style overrides; nil/false fields inherit the Text widget's base.
struct NudgeSpanStyle: Equatable {
    let fontWeight: Int?
    let fontSize: CGFloat?
    let color: Color?
    let highlightColor: Color?
    let italic: Bool
    /// Single decoration (not combinable).
    let underline: Bool
    let strikethrough: Bool
    /// Decoration line colour; nil = same as the text colour.
    let decorationColor: Color?
    /// Decoration line thickness in points; nil = default.
    let decorationThickness: CGFloat?
}

/// One styled run: its literal `text` plus a `style` bag (the wire `{ text, style }`).
struct NudgeTextSpan: Equatable {
    let text: String
    let style: NudgeSpanStyle
}

struct NudgeText: Equatable {
    let box: NudgeBox
    let text: String
    let fontSize: CGFloat
    let fontWeight: Int
    let color: Color
    let textAlignment: TextAlignment
    /// Block-level line height (unitless multiplier) for the whole text; nil = default.
    let lineHeight: CGFloat?
    /// Optional rich overlay; empty = render plain `text` with the base style.
    var spans: [NudgeTextSpan] = []
}

struct NudgeImage: Equatable {
    let box: NudgeBox
    let url: String
    let aspectRatio: CGFloat
    let fit: NudgeContentFit
    /// Loading placeholder shown while `url` loads; `nil` when the payload has none.
    let placeholder: ImagePlaceholder?
}

struct NudgeButton: Equatable {
    let box: NudgeBox
    let label: String
    let variant: NudgeButtonVariant
    let fontSize: CGFloat
    let fontWeight: Int
    let background: Color
    let textColor: Color
    let radius: CGFloat
    let actions: [EngageAction]
    let isPrimary: Bool
}

struct NudgeGap: Equatable {
    let box: NudgeBox
    let height: CGFloat
}

struct NudgeDivider: Equatable {
    let box: NudgeBox
    let thickness: CGFloat
    let indent: CGFloat
    let endIndent: CGFloat
    let color: Color
}

struct NudgeLottie: Equatable {
    let box: NudgeBox
    let url: String
    let height: CGFloat
    let loop: Bool
    let autoplay: Bool
    let fit: NudgeContentFit
    let aspectRatio: CGFloat
}

struct NudgeCarousel: Equatable {
    let box: NudgeBox
    let images: [String]
    let height: CGFloat
    let autoPlay: Bool
    let autoPlayIntervalMs: Int
    let loop: Bool
    let showIndicator: Bool
}

struct NudgeVideo: Equatable {
    let box: NudgeBox
    let url: String
    /// Width-to-height ratio; `0` keeps the fixed-height behavior.
    let aspectRatio: CGFloat
    let height: CGFloat
    let autoplay: Bool
    let loop: Bool
    let showControls: Bool
    let muted: Bool
}

// MARK: - Root column

struct NudgeColumn: Equatable {
    let crossAxisAlignment: NudgeCrossAxisAlignment
    let mainAxisAlignment: NudgeMainAxisAlignment
    let spacing: CGFloat
    let children: [NudgeNode]
}
