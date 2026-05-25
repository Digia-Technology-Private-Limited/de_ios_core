import Foundation

struct CarouselItem {
    let imageUrl: String
    let deepLink: String?
}

struct CarouselIndicatorConfig {
    let showIndicator: Bool
    let dotHeight: Double
    let dotWidth: Double
    let spacing: Double
    let dotColor: String
    let activeDotColor: String
    let indicatorEffectType: String
}

struct InlineCarouselConfig {
    let slotKey: String
    let items: [CarouselItem]
    let height: Double
    let autoPlay: Bool
    let autoPlayInterval: Int
    let animationDuration: Int
    let infiniteScroll: Bool
    let viewportFraction: Double
    let indicator: CarouselIndicatorConfig

    static func fromJson(_ json: [String: Any]) -> InlineCarouselConfig? {
        guard let slotKey = json["slot_key"] as? String, !slotKey.isEmpty else { return nil }
        guard let itemsRaw = json["items"] as? [[String: Any]], !itemsRaw.isEmpty else { return nil }

        let items: [CarouselItem] = itemsRaw.compactMap { itemJson in
            guard let imageUrl = itemJson["image_url"] as? String, !imageUrl.isEmpty else { return nil }
            return CarouselItem(imageUrl: imageUrl, deepLink: itemJson["deep_link"] as? String)
        }
        guard !items.isEmpty else { return nil }

        let ind = json["indicator"] as? [String: Any]
        let indicator = CarouselIndicatorConfig(
            showIndicator: ind?["show_indicator"] as? Bool ?? true,
            dotHeight: ind?["dot_height"] as? Double ?? 8,
            dotWidth: ind?["dot_width"] as? Double ?? 8,
            spacing: ind?["spacing"] as? Double ?? 12,
            dotColor: ind?["dot_color"] as? String ?? "#CBD5E1",
            activeDotColor: ind?["active_dot_color"] as? String ?? "#4945FF",
            indicatorEffectType: ind?["indicator_effect_type"] as? String ?? "slide"
        )

        return InlineCarouselConfig(
            slotKey: slotKey,
            items: items,
            height: json["height"] as? Double ?? 180,
            autoPlay: json["auto_play"] as? Bool ?? true,
            autoPlayInterval: json["auto_play_interval"] as? Int ?? 3000,
            animationDuration: json["animation_duration"] as? Int ?? 700,
            infiniteScroll: json["infinite_scroll"] as? Bool ?? true,
            viewportFraction: json["viewport_fraction"] as? Double ?? 0.88,
            indicator: indicator
        )
    }
}
