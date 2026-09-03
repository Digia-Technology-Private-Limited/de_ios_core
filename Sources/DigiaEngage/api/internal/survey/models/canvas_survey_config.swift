import Foundation

enum CanvasSurveySceneKind: Equatable {
    case question
    case content
    case result
}

enum CanvasSurveyManagedRole: Equatable {
    case progress
    case pageCount
    case timer
    case primaryNavigation
    case backNavigation
    case dismiss
}

struct CanvasSurveyAnswerHostElement: Equatable {
    let id: String
    let rect: CampaignCanvasRect
}

struct CanvasSurveyManagedHostElement: Equatable {
    let id: String
    let rect: CampaignCanvasRect
    let role: CanvasSurveyManagedRole
    let visible: Bool
    let label: String
    let doneLabel: String
    let colorHex: String
    let fillHex: String
    let trackColorHex: String
    let borderColorHex: String
    let borderWidth: CGFloat
    let cornerRadius: CGFloat
    let fontSize: CGFloat
    let gap: CGFloat
    let padding: CGFloat
    let progressStyle: String
}

enum CanvasSurveyHostElement: Equatable {
    case answer(CanvasSurveyAnswerHostElement)
    case managed(CanvasSurveyManagedHostElement)

    var id: String {
        switch self {
        case .answer(let host): return host.id
        case .managed(let host): return host.id
        }
    }

    var rect: CampaignCanvasRect {
        switch self {
        case .answer(let host): return host.rect
        case .managed(let host): return host.rect
        }
    }
}

struct CanvasSurveyDocument: Equatable {
    let canvas: CampaignCanvas
    let sharedUi: CampaignCanvas
    let canvasHosts: [CanvasSurveyHostElement]
    let sharedUiHosts: [CanvasSurveyManagedHostElement]
}

struct CanvasSurveySceneDocument: Equatable {
    let kind: CanvasSurveySceneKind
    let canvas: CampaignCanvas
    let sharedUi: CampaignCanvas
    let canvasHosts: [CanvasSurveyHostElement]
    let sharedUiHosts: [CanvasSurveyManagedHostElement]
}

struct CanvasSurveyConfig: Equatable {
    let designWidth: CGFloat
    let welcomeDocument: CanvasSurveyDocument?
    let scenesByBlockId: [String: CanvasSurveySceneDocument]

    func document(for node: SurveyNode) -> CanvasSurveySceneDocument? {
        scenesByBlockId[node.blockId]
    }
}
