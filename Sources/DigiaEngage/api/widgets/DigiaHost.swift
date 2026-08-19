import Combine
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

            // Between guide and survey/nudge: lets a survey/nudge that starts
            // while a floater is collapsed cover it "for free" via layering,
            // without `isModalCampaignActive` needing to know about z-order at
            // all — mirrors Android's identical `DigiaHost` ordering rationale
            // (`FloaterRenderer()` mounted before `SurveyRenderer`/`NudgeRenderer`).
            //
            // A direct SwiftUI sibling here, not wrapped in a
            // `UIViewControllerRepresentable` hosting its own nested
            // `UIHostingController` (the previous approach) — that nesting put a
            // second `_UIHostingView` inside this one, and Apple's private
            // representable-hosting hit-test dispatch resolved touches through it
            // inconsistently: the exact same tap coordinates, moments apart,
            // sometimes correctly reached the floater's content and sometimes
            // silently resolved to this outer view instead, with no code-level
            // trigger for which happened — confirmed live across many tests. A
            // plain SwiftUI sibling shares this single hosting context with
            // everything else here, so there's no second boundary for that
            // dispatch to disagree with itself across.
            FloaterOverlayView()
                .zIndex(3)

            NudgeOverlayView()
                .zIndex(5)

            SurveyRenderer(orchestrator: surveyOrchestrator)
                .zIndex(4)

            RecordingBadgeView()
                .zIndex(6)
        }
    }
}
