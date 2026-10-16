import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `requestReview`: the boundary is the system in-app review prompt.
@Suite("RequestReview action", .serialized, .tags(.actions, .integration))
@MainActor
struct RequestReviewActionTests {

    @Test("tapping a button authored with requestReview asks iOS for the review prompt once")
    func requestReviewAsksForThePrompt() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.button(steps: [
            ["type": "Action.requestReview"],
        ]))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the review prompt is asked for") { sdk.platform.reviewRequests > 0 }
        #expect(sdk.platform.reviewRequests == 1)
    }
}
}
