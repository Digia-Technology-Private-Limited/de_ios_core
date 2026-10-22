import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `customKV`: the `actions/fixtures/action_custom_kv` card, whose button sends
/// `{route: MissionsActive, source: banner}`. The payload is the app's to act on, so the boundary is the handler the app
/// registers through `DigiaConfig(actionHandlers:)` and `Digia.initialize`.
@Suite("CustomKV action", .serialized, .tags(.actions, .integration))
@MainActor
struct CustomKVActionTests {

    @Test("tapping a button authored with customKV hands its payload to the app")
    func customKVReachesTheAppHandler() async throws {
        let received = Received()
        let sdk = try await SdkHarness.start(
            loadCampaign("Actions/Fixtures/action_custom_kv.json"),
            actionHandlers: DigiaActionHandlers(customKV: { received.payloads.append($0) })
        )
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver("test_action_custom_kv")

        try await sdk.tap(id: SdkHarness.buttonId)

        try await sdk.waitUntil("the handler is called") { !received.payloads.isEmpty }
        #expect(received.payloads == [["route": "MissionsActive", "source": "banner"]])
    }

    @MainActor
    private final class Received {
        var payloads: [[String: String]] = []
    }
}
}
