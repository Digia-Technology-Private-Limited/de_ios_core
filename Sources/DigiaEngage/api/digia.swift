import Foundation
import SwiftUI
import UIKit

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()


/// Builds the composite SDK descriptor (schema v1):
///   `s=schema | b=binding | p=platform | [w=wrapper |] c=core`
/// The wrapper segment (`w`) is present only when a thin wrapper SDK
/// delegates to this engine (e.g. React Native).
func buildSdkVersion(
    binding: String,
    platform: String,
    wrapperVersion: String?,
    core: String
) -> String {
    var parts = ["s=1", "b=\(binding)", "p=\(platform)"]
    if let w = wrapperVersion, !w.isEmpty { parts.append("w=\(w)") }
    parts.append("c=\(core)")
    return parts.joined(separator: "|")
}

@MainActor
public enum Digia {
    /// Path suffix used to recognize the SDK's debug-settings deeplink. Digia
    /// doesn't own the host app's URL scheme, so this is a path convention the
    /// host routes on from its own deep-linking/`onOpenURL` handling — see
    /// `isDebugSettingsDeepLink`.
    public static let debugSettingsDeepLinkPath = "_digia/debug-settings"

    /// Whether `url` is the SDK's debug-settings deeplink.
    ///
    /// Matches the raw string, not `URL.path`: for `myapp://_digia/debug-settings`,
    /// URL parsing treats `_digia` as the host, not the path, so a path-only
    /// check would never match a custom scheme.
    public static func isDebugSettingsDeepLink(_ url: URL) -> Bool {
        let raw = url.absoluteString
        let afterScheme: Substring
        if let range = raw.range(of: "://") {
            afterScheme = raw[range.upperBound...]
        } else {
            afterScheme = raw[...]
        }
        let trimmed = afterScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed == debugSettingsDeepLinkPath
            || trimmed.hasSuffix("/\(debugSettingsDeepLinkPath)")
    }

    /// Presents the SDK's debug-only settings screen. Trigger from the host's
    /// own debug menu, or via a deeplink (see `isDebugSettingsDeepLink`).
    ///
    /// No-op outside a debug build.
    public static func presentDebugSettings(from presenter: UIViewController) {
        guard SDKInstance.shared.isDebugBuild else {
            log.e("presentDebugSettings() ignored — not a debug build")
            return
        }
        // The same link can reach here twice — the SDK opens the screen from its
        // own deeplink handling, and a host that still routes the link itself
        // calls in as well. Presenting a second time would only earn a UIKit
        // "already presenting" warning, so treat the screen as already open.
        guard !(presenter.presentedViewController is UIHostingController<DigiaDebugSettingsView>) else {
            return
        }
        let host = UIHostingController(rootView: DigiaDebugSettingsView())
        presenter.present(host, animated: true)
    }

    /// If `url` is the SDK's debug-settings deeplink, presents it and returns
    /// `true`; otherwise returns `false` so the host can continue its own routing.
    @discardableResult
    public static func handleDeepLink(_ url: URL, from presenter: UIViewController) -> Bool {
        guard isDebugSettingsDeepLink(url) else { return false }
        presentDebugSettings(from: presenter)
        return true
    }
    /// Initializes the Digia SDK. No-ops below iOS 17 — the SDUI rendering layer
    /// requires APIs (`Layout`, newer `SwiftUI` scroll/animation modifiers) that
    /// only exist from iOS 17 onward.
    public static func initialize(_ config: DigiaConfig) async throws {
        guard #available(iOS 17, *) else { return }
        try await SDKInstance.shared.initialize(config)
    }

    public static var requestHeaders: [String: String] { SDKInstance.shared.requestHeaders }

    public static var sdkVersion: String? {
        SDKInstance.shared.sdkVersion
    }

    /// No-ops below iOS 17 (see `initialize`).
    public static func register(_ plugin: DigiaCEPPlugin) {
        guard #available(iOS 17, *) else { return }
        SDKInstance.shared.register(plugin)
    }

    /// Replaces the Custom KV handler. Pass `nil` to restore the SDK no-op.
    public static func setCustomKVHandler(_ handler: CustomKVHandler?) {
        SDKInstance.shared.setCustomKVHandler(handler)
    }

    /// Replaces the deep-link handler. Pass `nil` to restore SDK handling.
    public static func setDeepLinkHandler(_ handler: DeepLinkHandler?) {
        SDKInstance.shared.setDeepLinkHandler(handler)
    }

    /// Replaces the external URL handler. Pass `nil` to restore SDK handling.
    public static func setOpenURLHandler(_ handler: OpenURLHandler?) {
        SDKInstance.shared.setOpenURLHandler(handler)
    }

    /// No longer does anything: native fetches the campaign bundle itself on every
    /// binding, React Native included. Kept so an older React Native bundle that still
    /// calls this keeps working against a newer core.
    @available(
        *, deprecated,
        message: "Native owns the campaign fetch on every binding; this is a no-op."
    )
    public static func populateCampaignBundle(_ bundleJson: String) {
        guard #available(iOS 17, *) else { return }
        SDKInstance.shared.populateCampaignBundle(bundleJson)
    }

    /// Delivers the campaign published under `campaignKey`, right now, with no CEP involved.
    ///
    /// For an app that owns its own triggering: no CleverTap / MoEngage / WebEngage decides
    /// what fires, the app does. The delivery is otherwise identical to a plugin's — same
    /// routing, same frequency capping, same screen targeting, same analytics — so a campaign
    /// that would be dropped for a CEP is dropped here too, for the same reason.
    ///
    /// `variables` override the dashboard-authored fallbacks for this one delivery, exactly
    /// as a CEP's trigger variables do.
    ///
    /// Returns the presentation, whose `outcome` names what actually happened. A campaign key
    /// that is not published, a screen that is not targeted or a frequency cap already spent
    /// all come back as a `dropped` outcome rather than a trap — this is a delivery path, and
    /// a delivery path never fails at its caller.
    ///
    /// Safe to call before the campaign bundle has loaded: the delivery is buffered and
    /// routed once the store is ready, the same way a plugin's is.
    @MainActor
    public static func triggerCampaign(
        _ campaignKey: String,
        variables: [String: String]? = nil
    ) -> CampaignPresentation {
        SDKInstance.shared.triggerCampaign(campaignKey, variables: variables)
    }

    public static func setThemeMode(_ mode: DigiaThemeMode) {
        SDKInstance.shared.setThemeMode(mode)
    }

    /// Silently dismisses any active nudge overlay without animation.
    /// Call this when the JS bundle reloads so that a nudge from the previous
    /// session doesn't remain stuck on screen.
    public static func dismissActiveNudge() {
        SDKInstance.shared.controller.forceNudgeDismiss()
    }

    /// True when any overlay (toast, dialog, bottom sheet, anchored tooltip/spotlight)
    /// is currently active. Used by host views to decide whether to forward hit tests
    /// to the SwiftUI layer or pass them through to content below.
    /// A story floater is the one campaign that is *sometimes* full screen: its window is a small
    /// box (covered by `floaterActiveRect` instead), but the story viewer covers everything while
    /// it is open or collapsing. So this includes the mounted story viewer and excludes the
    /// collapsed window, which is why the two properties are not simply "is a floater showing".
    ///
    /// Leaving it out is not a degraded hit test but no hit test at all: a host that has not been
    /// told an overlay is active claims only the window's old rect and every tap on the story —
    /// advance, close, mute — falls through to the app behind it.
    public static var hasActiveOverlay: Bool {
        let ctrl = SDKInstance.shared.controller
        return ctrl.activeStoryOverlay != nil
            || ctrl.activeNudge != nil
            || SDKInstance.shared.surveyOrchestrator.state != nil
            || SDKInstance.shared.floaterStoryOrchestrator.storyOverlayActive
            || SDKInstance.shared.guideOrchestrator.state != nil
    }

    /// The debug bubble's current on-screen frame (root overlay's coordinate
    /// space), or `nil` when hidden. Unlike `hasActiveOverlay`, a host needs the
    /// actual frame here to tell a touch on the bubble apart from empty SwiftUI
    /// space elsewhere.
    public static var debugBadgeFrame: CGRect? {
        SDKInstance.shared.debugOverlayControllerSnapshot().badgeFrame
    }

    /// The floating window's current on-screen frame (root overlay's coordinate
    /// space), or `nil` when none is showing. Same purpose as `debugBadgeFrame` — a
    /// floater is a small floating region rather than the full-screen overlay
    /// `hasActiveOverlay` already covers, so a host's hit-testing needs the actual
    /// frame to tell a touch on it apart from empty SwiftUI space elsewhere.
    ///
    /// Covers **both** floater subtypes: a PiP's media window and a story floater's
    /// canvas window are the same thing to a host — a small box that must take its
    /// own touches. They have separate orchestrators (a PiP owns an `AVPlayer` that
    /// a story window has no use for), and only one of them can ever be showing, so
    /// this reads whichever it is. A story window missing from here is not a
    /// degraded hit test but no hit test at all: RN's `hitTest` cannot tell a touch
    /// on a region this small apart from empty SwiftUI space, so every tap on the
    /// window fell straight through to the host's own content behind it.
    public static var floaterActiveRect: CGRect? {
        SDKInstance.shared.floaterOrchestrator.activeRect
            ?? SDKInstance.shared.floaterStoryOrchestrator.activeRect
    }

    /// Sets the authenticated user ID for analytics identity stitching.
    public static func setUserId(_ userId: String) {
        SDKInstance.shared.setUserId(userId)
    }

    /// Clears the authenticated user ID (e.g. on logout).
    public static func clearUserId() {
        SDKInstance.shared.clearUserId()
    }

    /// Clears inline content (carousels/stories) for the given `placementKeys`. Once
    /// loaded, inline content is retained indefinitely — hosts should call this on
    /// logout so a stale user's content doesn't linger across the account switch.
    /// No-op if `placementKeys` is empty.
    public static func clearInlineContent(_ placementKeys: String...) {
        clearInlineContent(placementKeys)
    }

    /// Array-taking overload of `clearInlineContent(_:)`, for callers (e.g. the RN
    /// bridge) that already have a `[String]` rather than individual arguments.
    public static func clearInlineContent(_ placementKeys: [String]) {
        SDKInstance.shared.clearInlineContent(placementKeys)
    }

    /// Clears all inline content (carousels/stories) across every placement.
    public static func clearAllInlineContent() {
        SDKInstance.shared.clearAllInlineContent()
    }

    /// Registers the RN render hook. When set, guides are treated as JS-rendered:
    /// on a guide trigger the SDK applies frequency capping and, if allowed, invokes
    /// this callback with a ``GuideRenderRequest`` — the trigger payload, the
    /// presentation id the coordinator minted for this delivery, and the guide's
    /// authored JSON — to ask JS to render. It does not render the guide natively.
    /// Used only by the React Native bridge.
    ///
    /// The id is what a later ``reportExternalGuideLifecycle(presentationId:event:)``
    /// call must use — it is the only thing that resolves back to the real
    /// presentation the CEP's hold is on.
    public static func setOnGuideRenderRequest(
        _ callback: ((GuideRenderRequest) -> Void)?
    ) {
        SDKInstance.shared.onGuideRenderRequest = callback
    }

    /// Reports a lifecycle transition for an externally-rendered guide's
    /// presentation — the JS-rendered path ``setOnGuideRenderRequest(_:)``
    /// started, correlated by the `presentationId` that callback received.
    ///
    /// This is the one way a renderer outside this core can drive a
    /// presentation: it never gets a ``PresentationController`` of its own to
    /// hold, only an id and a verb, so there is no way to end up settling a
    /// second, disconnected presentation instead of the real one.
    ///
    /// An unknown or already-settled `presentationId` is a silent no-op (with
    /// a DEBUG-only log) — never a trap. A Metro reload makes JS report
    /// lifecycle for a presentation native already settled on its own (a
    /// screen change, the acceptance watchdog); that is a designed race, not a
    /// caller error.
    ///
    /// Safe to call from any thread: React method calls arrive off the main
    /// thread, and this hops to the main actor itself before touching any SDK
    /// state, so a caller never needs its own `Task { @MainActor in ... }`
    /// wrapper just to reach this one entry point.
    nonisolated public static func reportExternalGuideLifecycle(
        presentationId: String,
        event: ExternalGuideLifecycleEvent
    ) {
        Task { @MainActor in
            SDKInstance.shared.reportExternalGuideLifecycle(
                presentationId: presentationId, event: event)
        }
    }

    /// Records an analytics event for JS-rendered campaigns (guides / tooltips / spotlights).
    /// Native campaigns (nudge, inline, survey) are tracked automatically by the SDK.
    /// The JS layer fires each lifecycle event by its Engage matrix `eventName` with
    /// wire-keyed `props`; the SDK maps it to the matching rich Digia analytics event.
    public static func captureAnalyticsEvent(
        campaignKey: String, eventName: String, props: [String: Any]
    ) {
        SDKInstance.shared.captureAnalyticsEvent(
            campaignKey: campaignKey, eventName: eventName, props: props)
    }

    /// Reports the current screen name for screen-scoped analytics and CEP forwarding.
    /// Matches Android's `Digia.setCurrentScreen(name:)` and Flutter's `Digia.setCurrentScreen`.
    ///
    /// Call this manually from `viewDidAppear` (see the `UIViewController.digiaScreen(_:)`
    /// extension for a drop-in helper), or add `DigiaNavigatorObserver` to your
    /// `UINavigationController`'s delegate chain for automatic tracking.
    public static func setCurrentScreen(name: String) {
        SDKInstance.shared.setCurrentScreen(name)
    }
}
