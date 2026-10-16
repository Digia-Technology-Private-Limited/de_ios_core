import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `customKV`: the payload is the app's to act on, so the boundary is the handler the app
/// registers through `DigiaConfig(actionHandlers:)` and `Digia.initialize`.
@Suite("CustomKV action", .serialized, .tags(.actions, .integration))
@MainActor
struct CustomKVActionTests {

    @Test("tapping a button authored with customKV hands its payload to the app")
    func customKVReachesTheAppHandler() async throws {
        let received = Received()
        let sdk = try await ActionHarness.start(
            ActionCampaigns.button(steps: [
                ["type": "Action.customKV",
                 "data": ["payload": ["route": "MissionsActive", "source": "banner"]]],
            ]),
            actionHandlers: DigiaActionHandlers(customKV: { received.payloads.append($0) })
        )
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the handler is called") { !received.payloads.isEmpty }
        #expect(received.payloads == [["route": "MissionsActive", "source": "banner"]])
    }

    @MainActor
    private final class Received {
        var payloads: [[String: String]] = []
    }
}
}
