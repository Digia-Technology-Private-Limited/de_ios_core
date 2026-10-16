import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `dismiss`: the Test Kit's `nudge-dialog`, unchanged, whose "Got It" button (`dialogButton`) is
/// authored `Action.dismissDialog`. The boundary is the screen itself: the dialog must be gone and
/// the app underneath back in front — and closed *by that CTA*. A backdrop tap or the close button
/// also removes it, so the outcome's reason is what tells a working dismiss from a stray touch.
@Suite("Hide action", .serialized, .tags(.actions, .integration))
@MainActor
struct HideActionTests {

    @Test("tapping a CTA authored with dismiss closes the nudge")
    func dismissClosesTheNudge() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.load("nudge_dialog", "nudge-dialog"))
        defer { sdk.tearDown() }
        try sdk.mount { Text("App home") }
        let presentation = try sdk.deliver("test_nudge_dialog")
        try await sdk.waitUntil("the dialog is on screen") { sdk.isShowing("Dialog Test Nudge") }

        try await sdk.tap(id: "dialogButton")

        try await sdk.waitUntil("the dialog is gone") { !sdk.isShowing("Dialog Test Nudge") }
        #expect(SDKInstance.shared.controller.activeNudge == nil)
        guard case .dismissed(let reason, _) = presentation.outcome.settledValue else {
            Issue.record("The nudge left the screen without settling as dismissed")
            return
        }
        #expect(reason == .ctaAction, "Closed by \(reason), not by the CTA")
        #expect(sdk.isShowing("App home"))
    }
}
}
