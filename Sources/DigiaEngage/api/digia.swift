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

    /// Records an analytics event for JS-rendered campaigns (guides / tooltips / spotlights).
    /// Native campaigns (nudge, inline, survey) are tracked automatically by the SDK.
    /// The campaign is resolved from the store by `payload.campaignKey` and the
    /// coarse event is mapped onto the matching rich Digia analytics event.
    public static func captureAnalyticsEvent(_ event: DigiaExperienceEvent, payload: CEPTriggerPayload) {
        SDKInstance.shared.captureAnalyticsEvent(event, payload: payload)
    }
}
