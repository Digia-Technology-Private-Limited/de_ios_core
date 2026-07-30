import Foundation

struct InlineBannerMargin: Equatable {
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0
    var left: Double = 0
}

enum InlineBannerBoxFit: Equatable {
    case cover
    case contain
    case fill
}

struct InlineBannerImageConfig: Equatable {
    let url: String
    var placeholder: ImagePlaceholder?
    var boxFit: InlineBannerBoxFit = .cover
    var aspectRatio: Double = 16 / 9
    var height: Double = 200
    var cornerRadius: Double = 12
}

struct InlineBannerConfig: Equatable {
    let slotKey: String
    let image: InlineBannerImageConfig
    var margin: InlineBannerMargin = .init()
    var actions: [EngageAction] = []
    var variableSchemas: [VariableSchema] = []

    static func fromJson(_ json: [String: Any]) -> InlineBannerConfig? {
        guard let slotKey = json.nonBlankString("slotKey"),
              let imageJson = json.object("image"),
              let imageUrl = imageJson.nonBlankString("url")
        else { return nil }
        let marginJson = json.object("layout")?.object("margin") ?? [:]
        let actions = EngageActionParser().parse(json.object("onClick")).filter {
            switch $0 {
            case .openUrl, .openDeeplink, .share, .copyToClipboard, .customKV: true
            default: false
            }
        }
        let boxFit: InlineBannerBoxFit
        switch imageJson.string("boxFit") {
        case "contain": boxFit = .contain
        case "fill": boxFit = .fill
        default: boxFit = .cover
        }
        return InlineBannerConfig(
            slotKey: slotKey,
            image: InlineBannerImageConfig(
                url: imageUrl,
                placeholder: ImagePlaceholder.from(imageJson.object("placeholder")),
                boxFit: boxFit,
                aspectRatio: nonNegative(imageJson.double("aspectRatio", default: 16 / 9), default: 16 / 9),
                height: nonNegative(imageJson.double("height", default: 200), default: 200),
                cornerRadius: nonNegative(imageJson.double("cornerRadius", default: 12), default: 12)
            ),
            margin: InlineBannerMargin(
                top: nonNegative(marginJson.double("top", default: 0), default: 0),
                right: nonNegative(marginJson.double("right", default: 0), default: 0),
                bottom: nonNegative(marginJson.double("bottom", default: 0), default: 0),
                left: nonNegative(marginJson.double("left", default: 0), default: 0)
            ),
            actions: actions,
            variableSchemas: NudgeConfig.parseVariableSchemas(json)
        )
    }
}

private func nonNegative(_ value: Double, default fallback: Double) -> Double {
    value.isFinite && value >= 0 ? value : fallback
}
