import SwiftUI
import Combine

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
        // Recorded in init, not registerPlaceholderIfNeeded()'s .onAppear:
        // .onAppear is unreliable for a zero-intrinsic-size EmptyView() (e.g.
        // the RN slot bridge's manually-embedded UIHostingController). init()
        // fires reliably regardless; recordSlot's own dedupe makes repeat
        // calls harmless.
        SDKInstance.shared.recordSlotSeen(placementKey)
    }

    public var body: some View {
        Group {
            if let payload = inlineController.getCampaign(placementKey) {
                slotContent(for: payload)
                    .id(payload.cepCampaignId)
                    .onAppear {
                        registerPlaceholderIfNeeded()
                    }
                    .task(id: payload.cepCampaignId) {
                        registerPlaceholderIfNeeded()
                        reportFirstRenderIfNeeded(payload)
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

    @ViewBuilder
    private func slotContent(for payload: CEPTriggerPayload) -> some View {
        if let carouselConfig = inlineController.getCarouselConfig(placementKey) {
            InlineCarouselRenderer.makeView(carouselConfig, payload: payload)
        } else if let bannerConfig = inlineController.getBannerConfig(placementKey) {
            DigiaInlineBannerView(config: bannerConfig, payload: payload)
        } else if let storyConfig = inlineController.getStoryConfig(placementKey) {
            DigiaInlineStoryView(config: storyConfig, payload: payload)
        } else if let canvasConfig = inlineController.getCanvasConfig(placementKey) {
            DigiaInlineCanvasView(config: canvasConfig, payload: payload)
        } else {
            // No renderable config resolved for this slot — clean up. CEP already
            // saw Impressed + Dismissed at route time (syncTemplate semantics).
            Color.clear.frame(height: 0)
                .onAppear { inlineController.dismissCampaign(placementKey) }
        }
    }

    // MARK: - CEP placeholder registration (iOS-specific)

    private func registerPlaceholderIfNeeded() {
        guard placeholderID == nil else { return }
        placeholderID = SDKInstance.shared.registerPlaceholderForSlot(propertyID: placementKey)
    }

    private func reportFirstRenderIfNeeded(_ payload: CEPTriggerPayload) {
        // Digia's impression fires once, the first time this slot actually renders
        // a given payload. CEP was already impressed instantly at route time
        // (syncTemplate). The payload-keyed task also fires when a mounted slot is
        // reused for another live-test invocation.
        guard impressedPayloadID != payload.cepCampaignId else { return }
        impressedPayloadID = payload.cepCampaignId
        SDKInstance.shared.reportSlotFirstRender(payload)
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
