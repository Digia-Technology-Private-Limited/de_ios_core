import SwiftUI
import Combine

/// Renders inline campaign content at a specific placement position.
@MainActor
public struct DigiaSlot<Placeholder: View>: View {
    public let placementKey: String
    private let placeholder: Placeholder
    @ObservedObject private var inlineController = SDKInstance.shared.inlineController
    @State private var visible = false
    // Teaser (inline canvas) motion: fade + slight scale in, fade + height collapse out.
    @State private var lastCanvas: LastCanvas?
    @State private var appeared = false
    @State private var collapsed = false
    @State private var canvasHeight: CGFloat = 0
    @State private var exitToken = 0

    private struct LastCanvas {
        let config: InlineCanvasConfig
        let payload: CEPTriggerPayload
    }

    private static var appearDuration: Double { 0.24 }
    private static var exitDuration: Double { 0.2 }
    private static var startScale: CGFloat { 0.96 }

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

    @ViewBuilder
    public var body: some View {
        // Empty, the slot emits nothing (an EmptyView placeholder is no stack child), so it
        // adds no spacing to the host's layout. `slot_visible` is not sent for an empty slot.
        let live = inlineController.getCampaign(placementKey)
        let liveCanvas = live != nil && isGamificationCanvas(placementKey)
        // Once a canvas teaser is dismissed, its last content stays for the exit animation.
        let ghost = live == nil ? lastCanvas : nil
        let animated = liveCanvas || ghost != nil
        if live != nil || ghost != nil {
            let reduced = GameMotion.reduced
            ZStack {
                content(ghost: ghost)
            }
            .background(SlotAppearanceReader(placementKey: placementKey))
            .background {
                if animated {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { if ghost == nil { canvasHeight = proxy.size.height } }
                            .onChange(of: proxy.size.height) { if ghost == nil { canvasHeight = $0 } }
                    }
                }
            }
            .frame(height: ghost != nil && collapsed ? 0 : nil, alignment: .top)
            .clippedIf(animated)
            .opacity(animated ? ((collapsed || !appeared) ? 0 : 1) : 1)
            .scaleEffect(animated && !reduced && !collapsed && !appeared ? Self.startScale : 1)
            .onAppear {
                recordCanvas()
                guard animated else { return }
                if reduced { appeared = true } else {
                    withAnimation(.easeOut(duration: Self.appearDuration)) { appeared = true }
                }
            }
            .onChange(of: live?.cepCampaignId) { _ in
                recordCanvas()
                exitToken += 1
                collapsed = false
            }
            .onChange(of: ghost != nil) { exiting in
                guard exiting else { return }
                runExit()
            }
        } else {
            placeholder
        }
    }

    /// Only a gamification entry teaser animates; every other inline canvas appears as-is.
    private func isGamificationCanvas(_ placementKey: String) -> Bool {
        guard inlineController.getCanvasConfig(placementKey) != nil,
            let payload = inlineController.getCampaign(placementKey)
        else { return false }
        return SDKInstance.shared.gamificationSurface.entryCampaign(payload)?.gamificationConfig != nil
    }

    private func recordCanvas() {
        guard isGamificationCanvas(placementKey),
            let config = inlineController.getCanvasConfig(placementKey),
            let payload = inlineController.getCampaign(placementKey)
        else { return }
        lastCanvas = LastCanvas(config: config, payload: payload)
    }

    private func runExit() {
        exitToken += 1
        let token = exitToken
        let finish = {
            guard token == exitToken, inlineController.getCampaign(placementKey) == nil else { return }
            lastCanvas = nil
            collapsed = false
            appeared = false
        }
        if GameMotion.reduced { finish(); return }
        withAnimation(.easeIn(duration: Self.exitDuration)) { collapsed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration, execute: finish)
    }

    @ViewBuilder
    private func content(ghost: LastCanvas?) -> some View {
        Group {
            if placementKey == SDKInstance.rewardsWidgetSlotKey {
                GameRewardsWidgetView()
            } else if let payload = inlineController.getCampaign(placementKey) ?? ghost?.payload {
                let deliveryID = payload.presentationId ?? payload.cepCampaignId
                slotContent(for: payload, ghost: ghost)
                    .id(deliveryID)
                    .background(SlotVisibilityReader(visible: $visible))
                    .task(id: "\(deliveryID)-\(visible)") {
                        // No once-guard here: EngageEventEmitter dedupes the impression
                        // per campaign and resets it when the slot is cleared, so a
                        // redelivery of the same CEP campaign ID impresses again.
                        if visible { SDKInstance.shared.inlineReporter.reportSlotFirstRender(payload) }
                        GamePrewarmer.entryVisibility(campaignKey: payload.campaignKey, visible: visible)
                    }
            } else {
                placeholder
            }
        }
    }

    @ViewBuilder
    private func slotContent(for payload: CEPTriggerPayload, ghost: LastCanvas?) -> some View {
        if let carouselConfig = inlineController.getCarouselConfig(placementKey) {
            CarouselStepScope(payload: payload) { gate in
                InlineCarouselRenderer.makeView(carouselConfig, payload: payload, stepGate: gate)
            }
        } else if let bannerConfig = inlineController.getBannerConfig(placementKey) {
            DigiaInlineBannerView(config: bannerConfig, payload: payload)
        } else if let storyConfig = inlineController.getStoryConfig(placementKey) {
            DigiaInlineStoryView(config: storyConfig, payload: payload)
        } else if let canvasConfig = inlineController.getCanvasConfig(placementKey) ?? ghost?.config {
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
}

@MainActor
public extension DigiaSlot where Placeholder == EmptyView {
    init(_ placementKey: String) {
        self.init(placementKey) {
            EmptyView()
        }
    }
}


/// Sends `slot_visible` each time a filled slot becomes exposed
/// (`ExposureMonitor`). An empty slot emits no view, so it is never exposed.
struct SlotAppearanceReader: UIViewRepresentable {
    let placementKey: String

    final class Coordinator {
        var tag: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let tag = "slot:\(placementKey)"
        if let previous = context.coordinator.tag, previous != tag {
            ExposureMonitor.shared.untrack(view, tag: previous)
        }
        context.coordinator.tag = tag
        let placementKey = placementKey
        ExposureMonitor.shared.track(view, tag: tag) {
            SDKInstance.shared.slotExposed(placementKey)
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        guard let tag = coordinator.tag else { return }
        ExposureMonitor.shared.untrack(view, tag: tag)
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

private extension View {
    @ViewBuilder
    func clippedIf(_ clip: Bool) -> some View {
        if clip { clipped() } else { self }
    }
}
