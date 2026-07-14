import Foundation

@MainActor
public enum Digia {
    /// Initializes the Digia SDK.
    public static func initialize(_ config: DigiaConfig) async throws {
        try await SDKInstance.shared.initialize(config)
    }

    public static func register(_ plugin: DigiaCEPPlugin) {
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

    /// RN-only: hand native the same getCampaigns response JS already fetched, so
    /// native doesn't also fetch it. Call once after `initialize` when the config's
    /// `wrapperBinding` is `"react_native"`.
    public static func populateCampaigns(_ campaignsJson: String) {
        SDKInstance.shared.populateCampaigns(campaignsJson)
    }

    public static func registerFontFactory(_ factory: DUIFontFactory) {
        SDKInstance.shared.registerFontFactory(factory)
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
    public static var hasActiveOverlay: Bool {
        let ctrl = SDKInstance.shared.controller
        return ctrl.activeStoryOverlay != nil
            || ctrl.activeNudge != nil
            || SDKInstance.shared.surveyOrchestrator.state != nil
    }

    /// Sets the authenticated user ID for analytics identity stitching.
    public static func setUserId(_ userId: String) {
        SDKInstance.shared.setUserId(userId)
    }

    /// Clears the authenticated user ID (e.g. on logout).
    public static func clearUserId() {
        SDKInstance.shared.clearUserId()
    }

    /// Registers the RN render hook. When set, guides are treated as JS-rendered:
    /// on a guide trigger the SDK applies frequency capping and, if allowed, invokes
    /// this callback (with the trigger payload) to ask JS to render — it does not
    /// render the guide natively. Used only by the React Native bridge.
    public static func setOnGuideRenderRequest(_ callback: ((CEPTriggerPayload) -> Void)?) {
        SDKInstance.shared.onGuideRenderRequest = callback
    }

    /// Records an analytics event for JS-rendered campaigns (guides / tooltips / spotlights).
    /// Native campaigns (nudge, inline, survey) are tracked automatically by the SDK.
    /// The JS layer fires each lifecycle event by its Engage matrix `eventName` with
    /// wire-keyed `props`; the SDK maps it to the matching rich Digia analytics event.
    public static func captureAnalyticsEvent(campaignKey: String, eventName: String, props: [String: Any]) {
        SDKInstance.shared.captureAnalyticsEvent(campaignKey: campaignKey, eventName: eventName, props: props)
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
