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
}
