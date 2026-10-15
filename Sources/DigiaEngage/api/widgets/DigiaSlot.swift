import SwiftUI
import Combine

/// Renders inline campaign content at a specific placement position.
@MainActor
public struct DigiaSlot<Placeholder: View>: View {
    public let placementKey: String
    private let placeholder: Placeholder
    @ObservedObject private var inlineController = SDKInstance.shared.inlineController
    @State private var impressedPayloadID: String?
    @State private var visible = false

    public init(
        _ placementKey: String,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.placementKey = placementKey
        self.placeholder = placeholder()
        // Recorded in init, not in an .onAppear: .onAppear is unreliable for a
        // zero-intrinsic-size EmptyView() (e.g. the RN slot bridge's
        // manually-embedded UIHostingController). init() fires reliably
        // regardless; recordSlot's own dedupe makes repeat calls harmless.
        SDKInstance.shared.recordSlotSeen(placementKey)
    }

    public var body: some View {
        Group {
            if let payload = inlineController.getCampaign(placementKey) {
                slotContent(for: payload)
                    .id(payload.cepCampaignId)
                    .background(SlotVisibilityReader(visible: $visible))
                    .task(id: "\(payload.cepCampaignId)-\(visible)") {
                        if visible { reportFirstRenderIfNeeded(payload) }
                    }
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private func slotContent(for payload: CEPTriggerPayload) -> some View {
        if let carouselConfig = inlineController.getCarouselConfig(placementKey) {
            CarouselStepScope(payload: payload) { gate in
                InlineCarouselRenderer.makeView(carouselConfig, payload: payload, stepGate: gate)
            }
        } else if let bannerConfig = inlineController.getBannerConfig(placementKey) {
            DigiaInlineBannerView(config: bannerConfig, payload: payload)
        } else if let storyConfig = inlineController.getStoryConfig(placementKey) {
            DigiaInlineStoryView(config: storyConfig, payload: payload)
        } else if let canvasConfig = inlineController.getCanvasConfig(placementKey) {
            CarouselStepScope(payload: payload) { gate in
                DigiaInlineCanvasView(config: canvasConfig, payload: payload, stepGate: gate)
            }
        } else {
            // No renderable config resolved for this slot — clean up. CEP already
            // saw Impressed + Dismissed at route time (syncTemplate semantics).
            Color.clear.frame(height: 0)
                .onAppear { inlineController.dismissCampaign(placementKey) }
        }
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


/// Reports whether the slot is on screen: in a window, with no hidden view
/// above it, while the app is active. SwiftUI's appear events miss hidden
/// UIKit and React Native hosts, so the slot checks the view hierarchy itself.
struct SlotVisibilityReader: UIViewRepresentable {
    @Binding var visible: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onChange = { visible = $0 }
        view.check()
    }

    final class ProbeView: UIView {
        var onChange: ((Bool) -> Void)?
        private var reported: Bool?
        private var appActive = UIApplication.shared.applicationState == .active

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Selector observers are removed with the view, so nothing leaks.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(resignedActive), name: UIApplication.willResignActiveNotification, object: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            check()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            check()
        }

        @objc private func becameActive() {
            appActive = true
            check()
        }

        @objc private func resignedActive() {
            appActive = false
            check()
        }

        func check() {
            var shown = window != nil && appActive
            var view: UIView? = self
            while shown, let current = view {
                shown = !current.isHidden
                view = current.superview
            }
            guard shown != reported else { return }
            reported = shown
            // SwiftUI state must not change during a view update.
            DispatchQueue.main.async { [onChange] in onChange?(shown) }
        }
    }
}
