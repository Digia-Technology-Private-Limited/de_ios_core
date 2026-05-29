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
