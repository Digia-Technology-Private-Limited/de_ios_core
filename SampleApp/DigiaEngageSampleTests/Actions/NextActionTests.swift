import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `next`: only a multi-step surface can move forward, so this drives the Test Kit's
/// `guide-spotlight-journey`, unchanged. Its first step's "Next" button (`btn_next`) is authored
/// `Action.next`.
@Suite("Next action", .serialized, .tags(.actions, .integration))
@MainActor
struct NextActionTests {

    @Test("tapping a button authored with next shows the following step")
    func nextShowsTheFollowingStep() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.load("guide_spotlight", "guide-spotlight-journey"))
        defer { sdk.tearDown() }
        try sdk.mount { GuideHostScreen() }
        try sdk.deliver("test_guide_spotlight_journey")
        try await sdk.waitUntil("step one is on screen") { sdk.isShowing("Canvas Search") }

        try await sdk.tap(id: "btn_next")

        try await sdk.waitUntil("step two is on screen") { sdk.isShowing("Daily Deals") }
        #expect(!sdk.isShowing("Canvas Search"))
    }
}
}
