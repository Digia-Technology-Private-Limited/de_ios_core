import Foundation

// Ported from Android `InlineStoryConfig.kt`.

struct StoryCtaAction: Equatable {
    let type: String
    let url: String?

    static func fromJson(_ json: [String: Any]) -> StoryCtaAction {
        StoryCtaAction(
            type: json.string("type", default: "dismiss"),
            url: json.nonBlankString("url")
        )
    }
}

struct StoryItemConfig: Equatable {
    let type: String
    let url: String
    let duration: Int?
    var thumbnailPlayback: StoryThumbnailPlaybackConfig = StoryThumbnailPlaybackConfig()
    var ctaEnabled: Bool = false
    var ctaText: String?
    var ctaFontWeight: Int = 600
    var ctaTextColor: String = "#FFFFFF"
    var ctaBackgroundColor: String = "#4945FF"
    var ctaCornerRadius: Int = 8
    var ctaAction: StoryCtaAction?
    var actions: [EngageAction] = []

    static func fromJson(_ json: [String: Any]) -> StoryItemConfig? {
        guard let url = json.nonBlankString("url") else { return nil }
        let ctaActionJson = json.object("ctaAction")
        let actions = ctaActionJson?["steps"] != nil
            ? EngageActionParser().parse(ctaActionJson)
            : parseLegacyStoryActions(ctaActionJson)
        let ctaAction = ctaActionJson.map(StoryCtaAction.fromJson)
        return StoryItemConfig(
            type: json.string("type", default: "image"),
            url: url,
            duration: json.positiveInt("duration"),
            thumbnailPlayback: StoryThumbnailPlaybackConfig.fromJson(
                json.object("thumbnailPlayback")
            ),
            ctaEnabled: json.bool("ctaEnabled", default: false),
            ctaText: json.nonBlankString("ctaText"),
            ctaFontWeight: DigiaFontWeight.value(json["ctaFontWeight"], default: 600),
            ctaTextColor: json.nonBlankString("ctaTextColor") ?? "#FFFFFF",
            ctaBackgroundColor: json.nonBlankString("ctaBackgroundColor") ?? "#4945FF",
            ctaCornerRadius: json.int("ctaCornerRadius", default: 8),
            ctaAction: ctaAction,
            actions: actions
        )
    }

    private static func parseLegacyStoryActions(
        _ ctaAction: [String: Any]?
    ) -> [EngageAction] {
        let type = ctaAction?.string("type", default: "dismiss") ?? "dismiss"
        let url = ctaAction?.nonBlankString("url")
        return switch type {
        case "deepLink": [url.map(EngageAction.openDeeplink), .dismiss].compactMap { $0 }
        case "openUrl": [url.map(EngageAction.openUrl), .dismiss].compactMap { $0 }
        default: [.dismiss]
        }
    }
}

enum StoryThumbnailDurationMode: String, Equatable {
    case full
    case fixed
}

struct StoryThumbnailPlaybackConfig: Equatable {
    var startTimeMs: Int64 = 0
    var durationMode: StoryThumbnailDurationMode = .full
    var durationMs: Int64?

    static func fromJson(_ json: [String: Any]?) -> StoryThumbnailPlaybackConfig {
        guard let json else { return StoryThumbnailPlaybackConfig() }
        let rawStart = json.double("startTimeMs", default: 0)
        let start =
            rawStart.isFinite && rawStart >= 0 && rawStart < Double(Int64.max)
                ? Int64(rawStart)
                : 0
        let rawDuration = json.double("durationMs", default: 0)
        let fixedDuration =
            rawDuration.isFinite && rawDuration > 0 && rawDuration < Double(Int64.max)
                ? Int64(rawDuration)
                : nil
        let mode: StoryThumbnailDurationMode =
            json.string("durationMode", default: "full") == "fixed" && fixedDuration != nil
                ? .fixed
                : .full
        return StoryThumbnailPlaybackConfig(
            startTimeMs: start,
            durationMode: mode,
            durationMs: fixedDuration
        )
    }
}

enum ThumbnailVideoPlaybackMode: String, Equatable {
    case simultaneous
    case sequential
}

struct StoryCardConfig: Equatable {
    var height: Int = 220
    var aspectRatio: Double = 0.6
    var borderRadius: Double = 12
    var spacing: Int = 8

    static func fromJson(_ json: [String: Any]?) -> StoryCardConfig {
        guard let json else { return StoryCardConfig() }
        let aspectRatio = json.double("aspectRatio", default: 0.6)
        return StoryCardConfig(
            height: json.positiveInt("height") ?? 220,
            aspectRatio: aspectRatio > 0 ? aspectRatio : 0.6,
            borderRadius: json.double("borderRadius", default: 12),
            spacing: json.int("spacing", default: 8)
        )
    }
}

struct StoryIndicatorDisplayConfig: Equatable {
    var activeColor: String = "#FFFFFF"
    var disabledColor: String = "#555555"
    var height: Double = 3.5
    var borderRadius: Double = 4
    var horizontalGap: Double = 4
    var topPadding: Double = 14
    var horizontalPadding: Double = 10

    static func fromJson(_ json: [String: Any]?) -> StoryIndicatorDisplayConfig {
        guard let json else { return StoryIndicatorDisplayConfig() }
        return StoryIndicatorDisplayConfig(
            activeColor: json.nonBlankString("activeColor") ?? "#FFFFFF",
            disabledColor: json.nonBlankString("disabledColor") ?? "#555555",
            height: json.double("height", default: 3.5),
            borderRadius: json.double("borderRadius", default: 4),
            horizontalGap: json.double("horizontalGap", default: 4),
            topPadding: json.double("topPadding", default: 14),
            horizontalPadding: json.double("horizontalPadding", default: 10)
        )
    }
}

struct InlineStoryConfig: Equatable {
    let slotKey: String
    var thumbnailVideoPlayback: ThumbnailVideoPlaybackMode = .simultaneous
    var defaultDuration: Int = 5000
    var restartOnCompleted: Bool = false
    var card: StoryCardConfig = StoryCardConfig()
    var indicator: StoryIndicatorDisplayConfig = StoryIndicatorDisplayConfig()
    let items: [StoryItemConfig]
    var variableSchemas: [VariableSchema] = []

    static func fromJson(_ json: [String: Any]) -> InlineStoryConfig? {
        guard let slotKey = json.nonBlankString("slotKey") else { return nil }
        let items = json.objectArray("items").compactMap { StoryItemConfig.fromJson($0) }
        if items.isEmpty { return nil }
        return InlineStoryConfig(
            slotKey: slotKey,
            thumbnailVideoPlayback:
                json.string("thumbnailVideoPlayback", default: "simultaneous") == "sequential"
                    ? .sequential
                    : .simultaneous,
            defaultDuration: json.positiveInt("defaultDuration") ?? 5000,
            restartOnCompleted: json.bool("restartOnCompleted", default: false),
            card: StoryCardConfig.fromJson(json.object("card")),
            indicator: StoryIndicatorDisplayConfig.fromJson(json.object("indicator")),
            items: items,
            variableSchemas: NudgeConfig.parseVariableSchemas(json)
        )
    }
}
