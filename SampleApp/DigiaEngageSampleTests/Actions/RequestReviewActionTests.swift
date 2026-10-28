import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `requestReview`: the `actions/fixtures/action_request_review` card. The boundary is the system
/// in-app review prompt.
@Suite("RequestReview action", .serialized, .tags(.actions, .integration))
@MainActor
struct RequestReviewActionTests {

    @Test("tapping a button authored with requestReview asks iOS for the review prompt once")
    func requestReviewAsksForThePrompt() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("actions/action_request_review.json"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver("test_action_request_review")

        try await sdk.tap(id: SdkHarness.buttonId)

        try await sdk.waitUntil("the review prompt is asked for") { sdk.platform.reviewRequests > 0 }
        #expect(sdk.platform.reviewRequests == 1)
    }
}
}
