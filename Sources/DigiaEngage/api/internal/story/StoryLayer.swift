import SwiftUI
import UIKit
internal import DigiaVideoEngine

/// How long a story opened from a rail takes to fade in; the same on every stack.
let storyFadeInDuration: TimeInterval = 0.2

/// Test seam for where the story layer appears. The package's test bundle runs without a host app,
/// where a modal presentation never gets its view laid out; tests of a story opening set a
/// controller here and the layer is added as a full-size child of it instead. Never set in
/// production, where `nil` leaves the presentation below unchanged.
@MainActor var storyLayerContainerOverride: UIViewController?

/// The one full-screen layer every story viewer opens in: the inline rail's story (classic and
/// canvas) and the story floater's.
///
/// A layer of its own, because a rail can sit inside a nudge, and a nudge is a modal of its own:
/// a story drawn in the host's layer would open underneath it. The floater draws its
/// grow-from-window hero inside this same layer, from the window's position on screen, so both
/// surfaces open the story the same way.
///
/// Presented as an `.overFullScreen` `UIHostingController` on the app's top-most view controller,
/// and deliberately NOT in a separate `UIWindow`. A raw secondary window works in a UIKit /
/// React-Native host, but in a SwiftUI `App`/`WindowGroup` host it renders its first frame and
/// then stays inert: SwiftUI never drives its update loop (frozen progress bar) and it never joins
/// the active responder chain (dead tap zones, swipe-dismiss and CTA). A modal presentation is
/// live and interactive in BOTH lifecycles. Being a UIKit modal layered above any React-Native
/// Fabric surface, it still owns its touches outright — without competing with Fabric's
/// `RCTSurfaceTouchHandler` — mirroring the isolation Android gets from a `Dialog`.
///
/// The layer itself never animates and never dims: presenting and dismissing are both instant and
/// the background is clear, so what arrives is whatever the content draws — a fade for a rail
/// (`fadeIn`), the hero for the floater. Each surface owns one instance, so a floater's layer and
/// a rail's never replace one another.
@MainActor
final class StoryLayer {
    /// The currently-presented controller. Weak because UIKit retains a presented controller for
    /// us; we only need it to drive dismissal.
    private weak var presented: UIViewController?

    var isPresented: Bool { presented != nil }

    init() {}

    /// Presents `content`, replacing whatever this layer already shows. `onEscape` is the hardware
    /// keyboard's ESC (e.g. simulator).
    func present<Content: View>(
        fadeIn: Bool,
        onEscape: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        // Tear the old one down so it doesn't collide with the incoming present.
        dismiss()

        let container = storyLayerContainerOverride
        let presenter = container == nil ? ViewControllerUtil.topViewController() : nil
        guard container != nil || presenter != nil else { return }

        let host = StoryLayerHostingController(
            rootView: StoryLayerRoot(fadeIn: fadeIn, content: content()),
            onEscape: onEscape
        )
        // Clear, so the floater's hero shows the app around it as it grows.
        host.view.backgroundColor = .clear
        host.modalPresentationStyle = .overFullScreen
        presented = host
        if let container {
            host.view.frame = container.view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addChild(host)
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
        } else {
            presenter?.present(host, animated: false)
        }
    }

    func dismiss() {
        guard let presented else { return }
        self.presented = nil
        if presented.parent != nil {
            presented.willMove(toParent: nil)
            presented.view.removeFromSuperview()
            presented.removeFromParent()
        } else {
            presented.presentingViewController?.dismiss(animated: false)
        }
    }
}

/// Fades a rail's story in; the floater passes `fadeIn: false`, because its hero is the transition.
private struct StoryLayerRoot<Content: View>: View {
    let fadeIn: Bool
    let content: Content
    @State private var alpha: Double

    init(fadeIn: Bool, content: Content) {
        self.fadeIn = fadeIn
        self.content = content
        _alpha = State(initialValue: fadeIn ? 0 : 1)
    }

    var body: some View {
        content
            .opacity(alpha)
            .onAppear {
                guard fadeIn else { return }
                withAnimation(.easeInOut(duration: storyFadeInDuration)) { alpha = 1 }
            }
    }
}

private final class StoryLayerHostingController<Content: View>: UIHostingController<Content> {
    private let onEscape: (() -> Void)?

    init(rootView: Content, onEscape: (() -> Void)?) {
        self.onEscape = onEscape
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder) {
        onEscape = nil
        super.init(coder: aDecoder)
    }

    // The interactive "back" (left-edge swipe) and swipe-down dismissals are
    // handled inside the SwiftUI DragGesture in the story content, not
    // by a UIKit gesture recognizer here — a separate UIScreenEdgePanGesture on
    // this view would be starved by SwiftUI's own pan recognizer. This
    // controller only adds hardware-keyboard ESC dismissal (e.g. simulator).
    override var canBecomeFirstResponder: Bool {
        true
    }

    override var keyCommands: [UIKeyCommand]? {
        guard onEscape != nil else { return nil }
        return [
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(escapePressed)
            )
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    @objc private func escapePressed() {
        onEscape?()
    }
}

/// What a story viewer reads from the environment that a new hosting controller does not inherit.
///
/// The layer is a controller of its own, so the presenting view's environment does not reach it.
/// A surface captures these where it is drawn (`@Environment(\.self)`) and applies them to the
/// content it presents.
struct StoryLayerEnvironment {
    let variables: VariableContext?
    let campaignKey: String?
    let interactions: CanvasInteractionReporter
    let lottieRuntime: CanvasLottieRuntime
    let mediaServices: MediaServices
    let slowNetwork: (any SlowNetworkSource)?

    init(_ values: EnvironmentValues) {
        variables = values.digiaVariables
        campaignKey = values.digiaCampaignKey
        interactions = values.canvasInteractions
        lottieRuntime = values.canvasLottieRuntime
        mediaServices = values.mediaServices
        slowNetwork = values.storySlowNetwork
    }

    func apply<V: View>(to view: V) -> some View {
        view
            .environment(\.digiaVariables, variables)
            .environment(\.digiaCampaignKey, campaignKey)
            .environment(\.canvasInteractions, interactions)
            .environment(\.canvasLottieRuntime, lottieRuntime)
            .environment(\.mediaServices, mediaServices)
            .environment(\.storySlowNetwork, slowNetwork)
    }
}
