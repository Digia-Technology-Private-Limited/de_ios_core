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
            if let payload = inlineController.getCampaign(placementKey) {
                slotContent(for: payload)
                    .onAppear {
                        registerPlaceholderIfNeeded()
                        // Digia's impression fires once, the first time the slot
                        // actually renders (deduped per campaign). CEP was already
                        // impressed instantly at route time (syncTemplate).
                        if impressedPayloadID != payload.cepCampaignId {
                            impressedPayloadID = payload.cepCampaignId
                            SDKInstance.shared.reportSlotFirstRender(payload)
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

    @ViewBuilder
    private func slotContent(for payload: CEPTriggerPayload) -> some View {
        if let carouselConfig = inlineController.getCarouselConfig(placementKey) {
            InlineCarouselRenderer.makeView(carouselConfig, payload: payload)
        } else if let storyConfig = inlineController.getStoryConfig(placementKey) {
            DigiaInlineStoryView(config: storyConfig, payload: payload)
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
}

@MainActor
public extension DigiaSlot where Placeholder == EmptyView {
    init(_ placementKey: String) {
        self.init(placementKey) {
            EmptyView()
        }
    }
}
