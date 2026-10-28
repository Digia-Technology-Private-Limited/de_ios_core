import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `HideAction` on every surface that can carry an authored CTA. Each surface ends its showing its
/// own way — a nudge or survey dismisses its sheet, a guide tears down its overlay, a PiP or story
/// floater ends the window mounted above the app — so each is driven through its own campaign. The
/// boundary is the screen itself: the surface must be gone and the app underneath back in front.
@Suite("Hide action", .serialized, .tags(.actions, .integration))
@MainActor
struct HideActionTests {

    /// The `nudge_dialog`, unchanged, whose "Got It" CTA (`dialogButton`) is authored
    /// `Action.dismissDialog`. The showing must settle as dismissed, not merely vanish.
    @Test("tapping a CTA authored with dismiss closes the nudge")
    func dismissClosesTheNudge() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("campaigns/nudge_dialog/nudge_dialog.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        let presentation = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }

        try await sdk.tap(id: "dialogButton")

        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        guard case .dismissed = presentation.outcome.settledValue else {
            Issue.record("The nudge left the screen without settling as dismissed")
            return
        }
        #expect(sdk.isShowing("App home"))
    }

    /// The `guide_tooltip_single_step`, unchanged, whose "Close" button (`dismiss_btn`) is authored
    /// `Action.dismiss`.
    @Test("tapping a button authored with dismiss closes the guide")
    func dismissClosesTheGuide() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("campaigns/guide_tooltip/guide_tooltip_single_step.json"))
        defer { sdk.tearDown() }
        try sdk.mount { GuideHostScreen() }
        try sdk.deliver("test_guide_tooltip_single")
        try await sdk.waitUntil("the guide is on screen") { sdk.isShowing("Quick Search Callout") }

        try await sdk.tap(id: "dismiss_btn")

        try await sdk.waitUntil("the guide is gone") { !sdk.isShowing("Quick Search Callout") }
        #expect(SDKInstance.shared.guideOrchestrator.state == nil)
    }

    /// The `survey_stacked_cta`, unchanged. Its result scene's "Close Survey" button
    /// (`btn_scene_stacked_done`) is authored `Action.hideBottomSheet`; the test answers the one
    /// question to reach it.
    @Test("tapping a button authored with dismiss closes the survey")
    func dismissClosesTheSurvey() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("campaigns/survey/survey_stacked_cta.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        try sdk.deliver("test_survey_stacked_cta")
        try await sdk.waitUntil("the survey is on screen") { sdk.isShowing("Option Alpha") }
        try await sdk.tap(text: "Option Alpha")
        try await sdk.tap(text: "Continue to Results")
        try await sdk.waitUntil("the result scene is on screen") { sdk.isShowing("All Done!") }

        try await sdk.tap(id: "btn_scene_stacked_done")

        try await sdk.waitUntil("the survey is gone") { !sdk.isShowing("All Done!") }
        #expect(SDKInstance.shared.surveyOrchestrator.state == nil)
        #expect(sdk.isShowing("App home"))
    }

    /// The `action_hide_pip`: `pip_expanded_canvas_cta` opened full screen, with its CTA
    /// (`pip_cta_button`) authored `Action.dismiss`. The PiP shows only once its image has loaded,
    /// and that image is the Test Kit's.
    ///
    /// Known gap, not a test problem: `FloaterSessionView` only mounts the expanded canvas when the
    /// surface *changes* to expanded, so a PiP authored `initialState: expanded` shows its chrome
    /// and image but never its canvas — the CTA is not there to tap. The PiP is delivered, its media
    /// is ready and its surface is expanded; only the content is missing. This test marks that with
    /// `withKnownIssue`, so it fails the day the content mounts, as the cue to drop the wrapper.
    @Test("tapping a CTA authored with dismiss closes the PiP",
          .enabled(if: testkitAvailable, testkitSkipReason))
    func dismissClosesThePip() async throws {
        let sdk = try await SdkHarness.start(loadCampaign("actions/action_hide_pip.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        try sdk.deliver("test_action_hide_pip")

        try await withKnownIssue("iOS never mounts a PiP's expanded canvas when it starts expanded") {
            try await sdk.waitUntil("the PiP is on screen", timeout: 3) {
                sdk.isShowing("Limited Time Health Drop")
            }

            try await sdk.tap(id: "pip_cta_button")

            try await sdk.waitUntil("the PiP is gone") { !sdk.isShowing("Limited Time Health Drop") }
            #expect(SDKInstance.shared.floaterOrchestrator.state == nil)
            #expect(sdk.isShowing("App home"))
        }
    }

    /// The `action_hide_floater_story`: `floater_story_window` with a story page whose CTA
    /// (`story_hide_button`) is authored `Action.dismiss`. The collapsed window opens the story;
    /// the CTA then ends the story, and Flutter ends its window with it.
    @Test("tapping a CTA authored with dismiss closes the story")
    func dismissClosesTheStoryFloater() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("actions/action_hide_floater_story.json"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        try sdk.deliver("test_action_hide_floater_story")
        let orchestrator = try #require(SDKInstance.shared.floaterStoryOrchestrator)
        try await sdk.waitUntil("the floater window is up") { orchestrator.activeRect != nil }
        TouchSynthesizer.drainRunLoop(for: 1)
        try FloaterTap.tapWindow(in: try #require(sdk.window))
        try await sdk.waitUntil("the story is open") { sdk.isShowing("Weekend Health Drop") }

        // The story grows out of its window; its frame reads steady before the viewer takes
        // touches, so let the expand finish.
        TouchSynthesizer.drainRunLoop(for: 1.5)
        try await sdk.tap(id: "story_hide_button")

        try await sdk.waitUntil("the story is gone") { !sdk.isShowing("Weekend Health Drop") }
        // Known gap: the story closes, but the floater window it grew out of stays up — `closeStory`
        // collapses back to the window unless the campaign authors `onStoryEnd: dismiss`, which this
        // fixture does not. Flutter ends the window too. `withKnownIssue` fails the day iOS does.
        try await withKnownIssue("iOS collapses a story floater to its window on a CTA's dismiss") {
            try await sdk.waitUntil("the window is gone", timeout: 2) { orchestrator.state == nil }
        }
        #expect(sdk.isShowing("App home"))
    }
}
}
