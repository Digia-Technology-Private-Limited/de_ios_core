import SwiftUI

/// Renders inline campaign content at a specific placement position.
@MainActor
public struct DigiaSlot<Placeholder: View>: View {
    public let placementKey: String
    private let placeholder: Placeholder
    @ObservedObject private var inlineController = SDKInstance.shared.inlineController
    @State private var placeholderID: Int?
    @State private var impressedPayloadID: String?

    public init(
        _ placementKey: String,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.placementKey = placementKey
        self.placeholder = placeholder()
    }

    public var body: some View {
        Group {
            if let slotConfig = inlineController.getSlotConfig(placementKey) {
                carouselView(for: slotConfig)
                    .onAppear { registerPlaceholderIfNeeded() }
            } else if let payload = inlineController.getCampaign(placementKey) {
                slotContent(for: payload)
                    .onAppear {
                        registerPlaceholderIfNeeded()
                        if impressedPayloadID != payload.id {
                            impressedPayloadID = payload.id
                            inlineController.onEvent?(.impressed, payload)
                        }
                    }
            } else {
                placeholder
                    .onAppear { registerPlaceholderIfNeeded() }
            }
        }
        .onDisappear {
            if let placeholderID {
                SDKInstance.shared.deregisterPlaceholderForSlot(placeholderID)
                self.placeholderID = nil
            }
        }
    }

    // MARK: - Native VWCarousel rendering

    @ViewBuilder
    private func carouselView(for config: InlineCarouselConfig) -> some View {
        if let widget = buildCarouselWidget(config) {
            let resources = ResourceProvider(
                fontFactory: SDKInstance.shared.fontFactory,
                appConfigStore: SDKInstance.shared.appConfigStore
            )
            widget.toWidget(RenderPayload(resources: resources))
        } else {
            placeholder
        }
    }

    private func buildCarouselWidget(_ config: InlineCarouselConfig) -> VWCarousel? {
        let ind = config.indicator

        let carouselDict: [String: Any] = [
            "height": config.height,
            "autoPlay": config.autoPlay,
            "autoPlayInterval": config.autoPlayInterval,
            "animationDuration": config.animationDuration,
            "infiniteScroll": config.infiniteScroll,
            "viewportFraction": config.viewportFraction,
            "padEnds": true,
            "showIndicator": ind.showIndicator,
            "dotHeight": ind.dotHeight,
            "dotWidth": ind.dotWidth,
            "spacing": ind.spacing,
            "dotColor": ind.dotColor,
            "activeDotColor": ind.activeDotColor,
            "indicatorEffectType": ind.indicatorEffectType,
            "dataSource": config.items.map { item -> [String: Any] in
                var d: [String: Any] = ["image_url": item.imageUrl]
                if let dl = item.deepLink { d["deep_link"] = dl }
                return d
            },
        ]

        let imageDict: [String: Any] = [
            "imageSrc": ["expr": "currentItem.image_url"],
            "fit": "cover",
        ]

        guard
            let carouselData = try? JSONSerialization.data(withJSONObject: carouselDict),
            let carouselProps = try? JSONDecoder().decode(CarouselProps.self, from: carouselData),
            let imageData = try? JSONSerialization.data(withJSONObject: imageDict),
            let imageProps = try? JSONDecoder().decode(ImageProps.self, from: imageData)
        else { return nil }

        let imageCommonProps = CommonProps(
            style: CommonStyle(widthRaw: "100%", heightRaw: "100%")
        )

        let imageWidget = VWImage(
            props: imageProps,
            commonProps: imageCommonProps,
            parentProps: nil,
            parent: nil,
            refName: nil
        )

        return VWCarousel(
            props: carouselProps,
            commonProps: nil,
            parentProps: nil,
            childGroups: ["child": [imageWidget]],
            parent: nil,
            refName: nil
        )
    }

    // MARK: - SDUI rendering

    @ViewBuilder
    private func slotContent(for payload: InAppPayload) -> some View {
        // Native carousel campaign (campaign_key path) — render via the SDUI carousel widget.
        if let carouselConfig = inlineController.getCarouselConfig(placementKey) {
            InlineCarouselRenderer.makeView(carouselConfig)
        } else {
            let viewId = payload.content.viewId ?? payload.content.placementKey

            if let viewId, !viewId.isEmpty {
                DUIFactory.shared.createComponent(viewId, args: payload.content.args)
            } else {
                // No viewId — collapse and dismiss.
                Color.clear.frame(height: 0)
                    .onAppear {
                        inlineController.onEvent?(.dismissed, payload)
                        inlineController.dismissCampaign(placementKey)
                    }
            }
        }
    }

    // MARK: - CEP placeholder registration (iOS-specific)

    private func registerPlaceholderIfNeeded() {
        guard placeholderID == nil else { return }
        placeholderID = SDKInstance.shared.registerPlaceholderForSlot(propertyID: placementKey)
    }
}

@MainActor
public extension DigiaSlot where Placeholder == EmptyView {
    init(_ placementKey: String) {
        self.init(placementKey) {
            EmptyView()
        }
    }
}
