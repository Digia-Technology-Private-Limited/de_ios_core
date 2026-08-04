import SwiftUI

let defaultCanvasDesignWidth: CGFloat = 360

enum NudgeCanvasBackground: Equatable {
    case color(Color)
    case image(url: String, positionX: CGFloat, positionY: CGFloat, scale: CGFloat)
    case gradient(angleDegrees: CGFloat, stops: [NudgeCanvasGradientStop])
}

struct NudgeCanvasGradientStop: Equatable {
    let color: Color
    let offset: CGFloat
}

struct NudgeCanvasRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

enum NudgeCanvasChild: Equatable {
    case widget(id: String, rect: NudgeCanvasRect, node: NudgeNode)
    case tapRegion(id: String, rect: NudgeCanvasRect, actions: [EngageAction])

    var id: String {
        switch self {
        case .widget(let id, _, _), .tapRegion(let id, _, _): id
        }
    }

    var rect: NudgeCanvasRect {
        switch self {
        case .widget(_, let rect, _), .tapRegion(_, let rect, _): rect
        }
    }
}

struct NudgeCanvas: Equatable {
    let version: Int
    let width: CGFloat
    let height: CGFloat
    let background: NudgeCanvasBackground
    /// Ordered back-to-front, matching the dashboard layer contract.
    let children: [NudgeCanvasChild]
}
