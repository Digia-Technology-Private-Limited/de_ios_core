import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `previous`: the `guide-spotlight-journey`, unchanged. Its second step's "Back"
/// button (`btn_back`) is authored `Action.previous`; the first step has none, so the test moves
/// forward once to reach it.
@Suite("Previous action", .serialized, .tags(.actions, .integration))
@MainActor
struct PreviousActionTests {

    @Test("tapping a button authored with previous shows the step before it")
    func previousShowsTheStepBefore() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("Campaigns/guide_spotlight/fixtures/guide-spotlight-journey.json"))
        defer { sdk.tearDown() }
        try sdk.mount { GuideHostScreen() }
        try sdk.deliver("test_guide_spotlight_journey")
        try await sdk.waitUntil("step one is on screen") { sdk.isShowing("Canvas Search") }
        try await sdk.tap(id: "btn_next")
        try await sdk.waitUntil("step two is on screen") { sdk.isShowing("Daily Deals") }

        try await sdk.tap(id: "btn_back")

        try await sdk.waitUntil("step one is back") { sdk.isShowing("Canvas Search") }
        #expect(!sdk.isShowing("Daily Deals"))
    }
}
}
