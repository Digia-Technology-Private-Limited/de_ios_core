import Foundation

// Ported from Android `InlineCarouselConfig.kt`.

struct CarouselItem: Equatable {
    let imageUrl: String
    let deepLink: String?
}

struct CarouselIndicatorConfig: Equatable {
    var showIndicator: Bool = true
    var dotHeight: Double = 8
    var dotWidth: Double = 8
    var spacing: Double = 12
    var dotColor: String = "#CBD5E1"
    var activeDotColor: String = "#4945FF"
    var indicatorEffectType: String = "slide"
}

struct InlineCarouselConfig: Equatable {
    let slotKey: String
    let items: [CarouselItem]
    var height: Int = 180
    var width: Int?
    var autoPlay: Bool = true
    var autoPlayInterval: Int64 = 3000
    var animationDuration: Int = 700
    var infiniteScroll: Bool = true
    var viewportFraction: Double = 0.88
    var indicator: CarouselIndicatorConfig = CarouselIndicatorConfig()
    /// Dashboard-declared variable schemas (name, type, fallback). Combined with
    /// the CEP trigger's runtime variables at render time via `buildVariableContext()`
    /// to interpolate `{{ }}` placeholders in image URLs / deep links — same as nudge & guide.
    var variableSchemas: [VariableSchema] = []

    static func fromJson(_ json: [String: Any]) -> InlineCarouselConfig? {
        guard let slotKey = json.nonBlankString("slotKey") else { return nil }

        let items: [CarouselItem] = json.objectArray("items").compactMap { itemJson in
            guard let imageUrl = itemJson.nonBlankString("imageUrl") else { return nil }
            return CarouselItem(imageUrl: imageUrl, deepLink: itemJson.nonBlankString("deepLink"))
        }
        if items.isEmpty { return nil }

        let indicator: CarouselIndicatorConfig
        if let indicatorJson = json.object("indicator") {
            indicator = CarouselIndicatorConfig(
                showIndicator: indicatorJson.bool("showIndicator", default: true),
                dotHeight: indicatorJson.double("dotHeight", default: 8),
                dotWidth: indicatorJson.double("dotWidth", default: 8),
                spacing: indicatorJson.double("spacing", default: 12),
                dotColor: indicatorJson.string("dotColor", default: "#CBD5E1"),
                activeDotColor: indicatorJson.string("activeDotColor", default: "#4945FF"),
                indicatorEffectType: indicatorJson.string("indicatorEffectType", default: "slide")
            )
        } else {
            indicator = CarouselIndicatorConfig()
        }

        return InlineCarouselConfig(
            slotKey: slotKey,
            items: items,
            height: json.int("height", default: 180),
            width: json.positiveInt("width"),
            autoPlay: json.bool("autoPlay", default: true),
            autoPlayInterval: json.long("autoPlayInterval", default: 3000),
            animationDuration: json.int("animationDuration", default: 700),
            infiniteScroll: json.bool("infiniteScroll", default: true),
            viewportFraction: json.double("viewportFraction", default: 0.88),
            indicator: indicator,
            variableSchemas: NudgeConfig.parseVariableSchemas(json)
        )
    }
}
