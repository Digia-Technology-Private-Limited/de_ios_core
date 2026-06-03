import SwiftUI
import UIKit
@MainActor
public struct DigiaHost<Content: View>: View {
    private let content: Content
    @ObservedObject private var controller = SDKInstance.shared.controller

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
                .onAppear { SDKInstance.shared.onHostMounted() }
                .onDisappear { SDKInstance.shared.onHostUnmounted() }

            if controller.bottomSheetRendersInHost,
               let sheet = controller.activeBottomSheet,
               let transition = controller.bottomSheetTransition {
                NavigationUtil.presentBottomSheetContent(
                    presentation: sheet,
                    overlayController: controller,
                    transition: transition,
                    dismissesPresentedViewController: false
                ) {
                    DigiaPresentationView(presentation: sheet.view)
                }
                .ignoresSafeArea()
                .zIndex(1)
            }

            GuideOverlayView()
                .zIndex(2)

            DigiaToastOverlay(toast: controller.activeToast)
                .zIndex(3)
        }
        .onChange(of: controller.activePayload, initial: false) { _, payload in
            handlePayload(payload)
        }
    }

    private func handlePayload(_ payload: InAppPayload?) {
        guard let payload else { return }
        guard let viewID = payload.content.viewId, !viewID.isEmpty else {
            controller.onEvent?(.dismissed, payload)
            controller.dismiss()
            return
        }

        controller.onEvent?(.impressed, payload)

        let appConfig = SDKInstance.shared.appConfigStore
        let executor = ActionExecutor()
        let context = ActionProcessorContext(appConfig: appConfig, actionExecutor: executor)
        let args = payload.content.args.isEmpty ? nil : JSONValue.object(payload.content.args)

        switch PayloadCommand(rawValue: payload.content.command ?? payload.content.type) {
        case .bottomSheet:
            let action = ShowBottomSheetAction(
                disableActionIf: nil,
                data: actionData(viewID: viewID, args: args)
            )
            Task { @MainActor in
                do {
                    try await ShowBottomSheetProcessor().execute(action: action, context: context)
                } catch {
                    assertionFailure("Failed to show bottom sheet: \(error)")
                }
                controller.onEvent?(.dismissed, payload)
                controller.dismiss()
            }
        case .dialog:
            var data = actionData(viewID: viewID, args: args)
            data["barrierDismissible"] = .bool(true)
            let action = ShowDialogAction(disableActionIf: nil, data: data)
            Task { @MainActor in
                do {
                    try await ShowDialogProcessor().execute(action: action, context: context)
                } catch {
                    assertionFailure("Failed to show dialog: \(error)")
                }
                controller.onEvent?(.dismissed, payload)
                controller.dismiss()
            }
        }
    }

    private func actionData(viewID: String, args: JSONValue?) -> [String: JSONValue] {
        var data: [String: JSONValue] = ["componentId": .string(viewID)]
        if let args {
            data["args"] = args
        }
        return data
    }
}

private struct DigiaToastOverlay: View {
    let toast: DigiaToastPresentation?

    var body: some View {
        VStack {
            Spacer()
            if let toast {
                Text(toast.message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast != nil)
    }
}

private enum PayloadCommand {
    case dialog
    case bottomSheet

    init(rawValue: String?) {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "SHOW_BOTTOM_SHEET", "BOTTOMSHEET":
            self = .bottomSheet
        default:
            self = .dialog
        }
    }
}
