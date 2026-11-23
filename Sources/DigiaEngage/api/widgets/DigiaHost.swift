import Combine
import SwiftUI
import UIKit

@MainActor
public struct DigiaHost<Content: View>: View {
    private let content: Content
    @ObservedObject private var controller = SDKInstance.shared.controller
    @ObservedObject private var surveyOrchestrator = SDKInstance.shared.surveyOrchestrator
    @ObservedObject private var hosts = HostRegistry.shared
    /// This host's identity in `HostRegistry`, which decides which host draws when there are several.
    @State private var hostId: UUID

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
        _hostId = State(initialValue: UUID())
    }

    /// For `DigiaHostView`, which must know the id to stop taking touches while another host draws.
    init(hostId: UUID, @ViewBuilder content: () -> Content) {
        self.content = content()
        _hostId = State(initialValue: hostId)
    }

    /// Only the active host draws (`HostRegistry`): with more than one host under `Digia.attach(to:)`,
    /// every other one renders just its content.
    private var drawsOverlays: Bool { hosts.isActive(hostId) }

    public var body: some View {
        ZStack {
            content

            // Above the floaters (3): a guide may show over a collapsed floater
            // (surface rule), and must be drawn over it like a nudge or survey.
            GuideOverlayView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zIndex(3.5)
                .shownIf(drawsOverlays)

            // Between guide and survey/nudge: lets a survey/nudge that starts
            // while a floater is collapsed cover it "for free" via layering,
            // without the surface rule needing to know about z-order at
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
                .shownIf(drawsOverlays)

            // Beside it, at the same layer: the two floater subtypes are separate
            // campaigns, and only one of them can ever be on screen at a time.
            FloaterStoryOverlayView()
                .zIndex(3)
                .shownIf(drawsOverlays)

            NudgeOverlayView()
                .zIndex(5)
                .shownIf(drawsOverlays)

            SurveyRenderer(orchestrator: surveyOrchestrator)
                .zIndex(4)
                .shownIf(drawsOverlays)

            RecordingBadgeView()
                .zIndex(6)
                .shownIf(drawsOverlays)

            CaptureFlashView()
                .zIndex(7)
                .shownIf(drawsOverlays)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // On the full-size host, not on `content`: SwiftUI never reports an `EmptyView` appearing, and
        // that is the content of every UIKit and React Native host.
        .onAppear { SDKInstance.shared.onHostMounted(hostId) }
        .onDisappear { SDKInstance.shared.onHostUnmounted(hostId) }
    }
}

private extension View {
    /// The view, or nothing at all: no drawing, no touches, no presentations.
    @ViewBuilder
    func shownIf(_ shown: Bool) -> some View {
        if shown { self }
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
