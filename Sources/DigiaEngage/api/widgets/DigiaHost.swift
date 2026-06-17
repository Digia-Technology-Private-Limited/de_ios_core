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

            NudgeOverlayView()
                .zIndex(5)

            SurveyRenderer(orchestrator: surveyOrchestrator)
                .zIndex(4)
        }
        .onChange(of: controller.activePayload, initial: false) { _, payload in
            // The generic typed-overlay path has no resolved campaign context, so
            // it no longer participates in analytics — just clear it.
            guard payload != nil else { return }
            controller.dismiss()
        }
    }
}
