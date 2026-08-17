import SwiftUI
import UIKit
import Combine

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

            RecordingBadgeView()
                .zIndex(6)

            CaptureFlashView()
                .zIndex(7)
        }
    }
}

@MainActor
private struct CaptureFlashView: View {
    @ObservedObject private var instance = SDKInstance.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 0.0

    var body: some View {
        Color.white
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: instance.captureFlashRevision) { _ in
                guard !reduceMotion else { return }
                opacity = 0.35
                withAnimation(.easeOut(duration: 0.15)) { opacity = 0 }
            }
    }
}
