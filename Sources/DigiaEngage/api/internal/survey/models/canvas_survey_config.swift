import Foundation

enum CanvasSurveySceneKind: Equatable {
    case question
    case content
    case result
}

enum CanvasSurveyInputProfile: Equatable {
    case choice
    case field
    case scale
}

enum CanvasSurveyInputType: Equatable {
    case singleSelect
    case multiSelect
    case upvote
    case shortText
    case longText
    case number
    case email
    case date
    case rating
    case reaction
    case numericNps
}

enum CanvasSurveyManagedRole: Equatable {
    case progress
    case pageCount
    case timer
    case primaryNavigation
    case backNavigation
    case dismiss
}

enum CanvasSurveyChoiceLayout: Equatable {
    case list
    case row
    case grid
}

enum CanvasSurveyOptionStyleMode: Equatable {
    case shared
    case individual
}

enum CanvasSurveyNumericNpsVariant: Equatable {
    case rounded
    case circle
}

struct CanvasSurveyInputStyle: Equatable {
    var layout: CanvasSurveyChoiceLayout = .list
    var columns: Int = 1
    var itemGap: CGFloat = 8
    var fontSize: CGFloat = 15
    var fontWeight: Int = 500
    var textColor: CampaignColor = .literal("#FF18181B")
    var selectedTextColor: CampaignColor = .literal("#FFFFFFFF")
    var selectedFill: CampaignColor = .literal("#FF4945FF")
    var unselectedFill: CampaignColor = .literal("#FFFFFFFF")
    var selectedBorderColor: CampaignColor = .literal("#FF4945FF")
    var borderColor: CampaignColor = .literal("#FFE4E4E7")
    var borderWidth: CGFloat = 1
    var cornerRadius: CGFloat = 12
    var padding: CGFloat = 12

    func merge(_ override: CanvasSurveyInputStyleOverride) -> CanvasSurveyInputStyle {
        CanvasSurveyInputStyle(
            layout: override.layout ?? layout,
            columns: override.columns ?? columns,
            itemGap: override.itemGap ?? itemGap,
            fontSize: override.fontSize ?? fontSize,
            fontWeight: override.fontWeight ?? fontWeight,
            textColor: override.textColor ?? textColor,
            selectedTextColor: override.selectedTextColor ?? selectedTextColor,
            selectedFill: override.selectedFill ?? selectedFill,
            unselectedFill: override.unselectedFill ?? unselectedFill,
            selectedBorderColor: override.selectedBorderColor ?? selectedBorderColor,
            borderColor: override.borderColor ?? borderColor,
            borderWidth: override.borderWidth ?? borderWidth,
            cornerRadius: override.cornerRadius ?? cornerRadius,
            padding: override.padding ?? padding
        )
    }
}

struct CanvasSurveyInputStyleOverride: Equatable {
    var layout: CanvasSurveyChoiceLayout?
    var columns: Int?
    var itemGap: CGFloat?
    var fontSize: CGFloat?
    var fontWeight: Int?
    var textColor: CampaignColor?
    var selectedTextColor: CampaignColor?
    var selectedFill: CampaignColor?
    var unselectedFill: CampaignColor?
    var selectedBorderColor: CampaignColor?
    var borderColor: CampaignColor?
    var borderWidth: CGFloat?
    var cornerRadius: CGFloat?
    var padding: CGFloat?
}

struct CanvasSurveyOptionText: Equatable {
    let text: String
    var typography: CampaignTypography = CampaignTypography()
    var color: CampaignColor?
}

struct CanvasSurveyOptionPresentation: Equatable {
    var text: CanvasSurveyOptionText?
    var styleOverride: CanvasSurveyInputStyleOverride = CanvasSurveyInputStyleOverride()
}

struct CanvasSurveyOption: Equatable {
    let id: String
    let label: String
    var presentation = CanvasSurveyOptionPresentation()
}

struct CanvasSurveyChoiceInput: Equatable {
    let type: CanvasSurveyInputType
    let required: Bool
    let style: CanvasSurveyInputStyle
    let options: [CanvasSurveyOption]
    let maximumSelections: Int?
    let optionStyleMode: CanvasSurveyOptionStyleMode
    let sharedText: CanvasSurveyOptionText?
}

struct CanvasSurveyFieldInput: Equatable {
    let type: CanvasSurveyInputType
    let required: Bool
    let style: CanvasSurveyInputStyle
    let placeholder: String
    let minLength: Int?
    let maxLength: Int?
    let minimum: Double?
    let maximum: Double?
    let multilineRows: Int
}

struct CanvasSurveyScaleInput: Equatable {
    let type: CanvasSurveyInputType
    let required: Bool
    let style: CanvasSurveyInputStyle
    let minimum: Double
    let maximum: Double
    let step: Double
    let symbolSize: CGFloat
    let numericNpsVariant: CanvasSurveyNumericNpsVariant
}

enum CanvasSurveyWireInput: Equatable {
    case choice(CanvasSurveyChoiceInput)
    case field(CanvasSurveyFieldInput)
    case scale(CanvasSurveyScaleInput)

    var profile: CanvasSurveyInputProfile {
        switch self {
        case .choice: return .choice
        case .field: return .field
        case .scale: return .scale
        }
    }

    var type: CanvasSurveyInputType {
        switch self {
        case .choice(let input): return input.type
        case .field(let input): return input.type
        case .scale(let input): return input.type
        }
    }

    var required: Bool {
        switch self {
        case .choice(let input): return input.required
        case .field(let input): return input.required
        case .scale(let input): return input.required
        }
    }
}

struct CanvasSurveyAnswerHostElement: Equatable {
    let id: String
    let rect: CampaignCanvasRect
    var presentationStyle = CanvasSurveyInputStyle()
    var optionPresentations: [String: CanvasSurveyOptionPresentation] = [:]
    var optionStyleModeOverride: CanvasSurveyOptionStyleMode?
    var sharedText: CanvasSurveyOptionText?
    var maximumSelectionsOverride: Int?
    var symbolSize: CGFloat = 0
    var numericNpsVariant: CanvasSurveyNumericNpsVariant = .rounded
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
    let countQuestionsOnly: Bool
    let iconColorHex: String?
    let iconSize: CGFloat
    let button: CampaignCanvasWidget?
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
    var input: CanvasSurveyWireInput? = nil
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
