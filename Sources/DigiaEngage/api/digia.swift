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

    /// Triggers a fetched Digia campaign directly by campaign id or campaign key.
    ///
    /// This is intended for QA/manual testing and mirrors the Android helper.
    /// The SDK must be initialized first so campaigns have been fetched.
    public static func triggerCampaign(_ campaignId: String) {
        SDKInstance.shared.triggerCampaign(campaignId)
    }

    public static func registerFontFactory(_ factory: DUIFontFactory) {
        SDKInstance.shared.registerFontFactory(factory)
    }

    @discardableResult
    public static func onMessage(
        _ name: String,
        listener: @escaping @Sendable (JSONValue?) -> Void
    ) -> UUID {
        SDKInstance.shared.addMessageListener(name: name, listener: listener)
    }

    public static func removeMessageListener(_ name: String, token: UUID) {
        SDKInstance.shared.removeMessageListener(name: name, token: token)
    }

    /// True when any overlay (toast, dialog, bottom sheet, anchored tooltip/spotlight)
    /// is currently active. Used by host views to decide whether to forward hit tests
    /// to the SwiftUI layer or pass them through to content below.
    public static var hasActiveOverlay: Bool {
        let ctrl = SDKInstance.shared.controller
        return ctrl.activeToast != nil
            || ctrl.activeAnchoredOverlay != nil
            || ctrl.activeBottomSheet != nil
            || ctrl.activeDialog != nil
    }
}
