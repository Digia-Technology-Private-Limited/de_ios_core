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

struct NudgeText: Equatable {
    let box: NudgeBox
    let text: String
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let color: Color
    let textAlignment: TextAlignment
}

struct NudgeImage: Equatable {
    let box: NudgeBox
    let url: String
    let aspectRatio: CGFloat
    let contentMode: ContentMode
}

struct NudgeButton: Equatable {
    let box: NudgeBox
    let label: String
    let variant: NudgeButtonVariant
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    let background: Color
    let textColor: Color
    let radius: CGFloat
    let actions: [NudgeAction]
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
