import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `share`: the boundary is the system share sheet.
@Suite("Share action", .serialized, .tags(.actions, .integration))
@MainActor
struct ShareActionTests {

    @Test("tapping a button authored with share opens the share sheet with its text")
    func shareOpensTheShareSheet() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.button(steps: [
            ["type": "Action.share", "data": ["message": "Get 20% off with code SAVE20"]],
        ]))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the share sheet is asked for") { !sdk.platform.shared.isEmpty }
        #expect(sdk.platform.shared == ["Get 20% off with code SAVE20"])
    }
}
}
