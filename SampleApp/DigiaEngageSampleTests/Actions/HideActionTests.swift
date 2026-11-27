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

    /// The `action_hide_floater_story`: `floater_story_window` with a story page whose CTA
    /// (`story_hide_button`) is authored `Action.dismiss`. The collapsed window opens the story;
    /// the CTA then ends the story, and Flutter ends its window with it.
}
}
