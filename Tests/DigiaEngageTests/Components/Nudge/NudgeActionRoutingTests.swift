import Foundation
import Testing
@testable import DigiaEngage

@Suite("Nudge action routing", .serialized, .tags(.nudge, .unit))
struct NudgeActionRoutingTests {

    @Test("performCanvasAction with empty actions executes defer and returns safely") @MainActor
    func testPerformCanvasActionEmptyActions() {
        var didDismiss = false
        let request = CampaignCanvasActionRequest(
            actions: [],
            elementId: "empty_btn",
            label: "No Action",
            isPrimary: false
        )
        performCanvasAction(request, variables: nil) {
            didDismiss = true
        }
        #expect(!didDismiss)
    }

    @Test("performCanvasAction with dismiss action invokes dismiss closure") @MainActor
    func testPerformCanvasActionDismissAction() async throws {
        var didDismiss = false
        let request = CampaignCanvasActionRequest(
            actions: [.dismiss],
            elementId: "dismiss_btn",
            label: "Close",
            isPrimary: true
        )
        performCanvasAction(request, variables: nil) {
            didDismiss = true
        }
        // Task executes asynchronously via LocalActionExecutor
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(didDismiss)
    }

    @Test("performCanvasAction with variable context interpolates action parameters") @MainActor
    func testPerformCanvasActionWithVariables() async throws {
        var didDismiss = false
        let variables = VariableContext(
            values: ["userId": "user_123"],
            types: ["userId": "string"]
        )
        let request = CampaignCanvasActionRequest(
            actions: [.openDeeplink("app://user/{{ userId }}")],
            elementId: "link_btn",
            label: "Profile",
            isPrimary: false
        )
        performCanvasAction(request, variables: variables) {
            didDismiss = true
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        // Non-local action is rejected by LocalActionExecutor, dismiss is not called
        #expect(!didDismiss)
    }
}
