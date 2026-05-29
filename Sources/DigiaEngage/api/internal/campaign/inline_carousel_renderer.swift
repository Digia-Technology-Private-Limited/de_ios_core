import SwiftUI

// Renders an InlineCarouselConfig by reusing the SDUI VWCarousel widget, mirroring
// Android's `DigiaComposableApi.buildCarouselWidget`: the native carousel config is
// mapped onto a carousel widget node (with a repeated network-image child) and
// rendered through the existing SDUI engine.
@MainActor
enum InlineCarouselRenderer {
    static func makeView(_ config: InlineCarouselConfig) -> AnyView {
        guard let widget = buildWidget(config) else { return AnyView(EmptyView()) }
        let runtime = SDKInstance.shared
        let payload = RenderPayload(
            resources: ResourceProvider(fontFactory: runtime.fontFactory, appConfigStore: runtime.appConfigStore)
        )
        return widget.toWidget(payload)
    }

    private static func buildWidget(_ config: InlineCarouselConfig) -> VirtualWidget? {
        let dataSource: [JSONValue] = config.items.map { item in
            .object([
                "image_url": .string(item.imageUrl),
                "deep_link": item.deepLink.map(JSONValue.string) ?? .null,
            ])
        }

        let imageNode: JSONValue = .object([
            "type": .string("digia/image"),
            "props": .object([
                "imageSrc": .object(["expr": .string("currentItem.image_url")]),
                "sourceType": .string("network"),
                "fit": .string("cover"),
            ]),
            "containerProps": .object([
                "style": .object([
                    "width": .string("100%"),
                    "height": .string("100%"),
                ]),
            ]),
        ])

        let ind = config.indicator
        var carouselProps: [String: JSONValue] = [
            "height": .int(config.height),
            "autoPlay": .bool(config.autoPlay),
            "autoPlayInterval": .int(Int(config.autoPlayInterval)),
            "animationDuration": .int(config.animationDuration),
            "infiniteScroll": .bool(config.infiniteScroll),
            "viewportFraction": .double(config.viewportFraction),
            "padEnds": .bool(true),
            "showIndicator": .bool(ind.showIndicator),
            "dotHeight": .double(ind.dotHeight),
            "dotWidth": .double(ind.dotWidth),
            "spacing": .double(ind.spacing),
            "dotColor": .string(ind.dotColor),
            "activeDotColor": .string(ind.activeDotColor),
            "indicatorEffectType": .string(ind.indicatorEffectType),
            "dataSource": .array(dataSource),
        ]
        if let width = config.width {
            carouselProps["width"] = .int(width)
        }

        let carouselNode: JSONValue = .object([
            "type": .string("digia/carousel"),
            "props": .object(carouselProps),
            "children": .object(["child": .array([imageNode])]),
        ])

        let registry = DefaultVirtualWidgetRegistry()
        do {
            let data = try JSONEncoder().encode(carouselNode)
            let vwData = try JSONDecoder().decode(VWData.self, from: data)
            return try registry.createWidget(vwData, parent: nil)
        } catch {
            return nil
        }
    }
}
