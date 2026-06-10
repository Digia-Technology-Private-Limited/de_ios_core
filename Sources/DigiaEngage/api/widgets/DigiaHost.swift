import SwiftUI
import UIKit

@MainActor
public struct DigiaHost<Content: View>: View {
    private let content: Content
    @ObservedObject private var controller = SDKInstance.shared.controller
    @ObservedObject private var surveyOrchestrator = SDKInstance.shared.surveyOrchestrator

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        ZStack {
            content
                .onAppear { SDKInstance.shared.onHostMounted() }
                .onDisappear { SDKInstance.shared.onHostUnmounted() }

            GuideOverlayView()
                .zIndex(2)

            DigiaToastOverlay(toast: controller.activeToast)
                .zIndex(3)

            NudgeOverlayView()
                .zIndex(5)
                .animation(.easeInOut(duration: 0.25), value: controller.activeNudge)

            SurveyRenderer(orchestrator: surveyOrchestrator)
                .zIndex(4)
        }
        .onChange(of: controller.activePayload, initial: false) { _, payload in
            guard let payload else { return }
            controller.onEvent?(.dismissed, payload)
            controller.dismiss()
        }
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
