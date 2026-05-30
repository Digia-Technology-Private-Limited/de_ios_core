import SwiftUI

struct AnchoredOverlayState: Equatable, Sendable {
    let payload: InAppPayload
    let anchorKey: String
    let anchorRect: CGRect
    let command: String  // "SHOW_TOOLTIP" or "SHOW_SPOTLIGHT"
    let cornerRadius: CGFloat  // spotlight cutout corner radius
}

struct InlineStoryOverlayState: Equatable {
    let config: InlineStoryConfig
    let initialIndex: Int
    let payload: InAppPayload
}

@MainActor
final class DigiaOverlayController: ObservableObject {
    @Published private(set) var activePayload: InAppPayload?
    @Published private(set) var activeBottomSheet: DigiaBottomSheetPresentation?
    @Published private(set) var activeDialog: DigiaDialogPresentation?
    @Published private(set) var activeToast: DigiaToastPresentation?
    @Published private(set) var slotPayloads: [String: InAppPayload] = [:]
    @Published private(set) var activeAnchoredOverlay: AnchoredOverlayState?
    @Published private(set) var activeStoryOverlay: InlineStoryOverlayState?

    private var toastToken = UUID()
    var onEvent: ((DigiaExperienceEvent, InAppPayload) -> Void)?
    var onDialogDismissed: ((JSONValue?) -> Void)?
    var onBottomSheetDismissed: ((JSONValue?) -> Void)?
    var bottomSheetTransition: BottomSheetTransitionModel?
    private(set) var bottomSheetRendersInHost = false

    func show(_ payload: InAppPayload) {
        activePayload = payload
    }

    func dismiss() {
        activePayload = nil
    }

    func showBottomSheet(_ presentation: DigiaBottomSheetPresentation, rendersInHost: Bool = false)
    {
        activeBottomSheet = presentation
        bottomSheetRendersInHost = rendersInHost
    }

    func dismissBottomSheet(result: JSONValue? = nil) {
        bottomSheetTransition = nil
        bottomSheetRendersInHost = false
        activeBottomSheet = nil
        onBottomSheetDismissed?(result)
        onBottomSheetDismissed = nil
    }

    func showDialog(_ presentation: DigiaDialogPresentation) {
        activeDialog = presentation
    }

    func dismissDialog(result: JSONValue? = nil) {
        activeDialog = nil
        onDialogDismissed?(result)
        onDialogDismissed = nil
    }

    func showToast(_ presentation: DigiaToastPresentation) {
        activeToast = presentation
        let token = UUID()
        toastToken = token
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(max(presentation.durationSeconds, 0) * 1_000_000_000))
            if self.toastToken == token {
                self.dismissToast()
            }
        }
    }

    func dismissToast() {
        activeToast = nil
    }

    func addSlot(_ placementKey: String, payload: InAppPayload) {
        slotPayloads[placementKey] = payload
    }

    func slotPayload(for placementKey: String) -> InAppPayload? {
        slotPayloads[placementKey]
    }

    func removeSlotByID(_ campaignID: String) {
        slotPayloads = slotPayloads.filter { _, payload in payload.id != campaignID }
    }

    func clearSlots() {
        slotPayloads.removeAll()
    }

    func showAnchored(_ state: AnchoredOverlayState) {
        activeAnchoredOverlay = state
    }

    func dismissAnchored() {
        activeAnchoredOverlay = nil
    }

    func showStoryOverlay(config: InlineStoryConfig, initialIndex: Int, payload: InAppPayload) {
        let state = InlineStoryOverlayState(
            config: config,
            initialIndex: initialIndex,
            payload: payload
        )
        activeStoryOverlay = state
        // The full-screen story is presented in its own dedicated UIWindow
        // (DigiaStoryWindowPresenter), not as an in-host SwiftUI overlay. A
        // separate key window sits above all React Native content and owns its
        // touches outright, so taps / swipes / the CTA work without competing
        // with Fabric's RCTSurfaceTouchHandler.
        DigiaStoryWindowPresenter.shared.present(state: state)
    }

    func dismissStoryOverlay() {
        activeStoryOverlay = nil
        DigiaStoryWindowPresenter.shared.dismiss()
    }
}
