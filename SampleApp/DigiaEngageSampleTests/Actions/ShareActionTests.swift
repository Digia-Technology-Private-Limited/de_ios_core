import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `share`: the `actions/fixtures/action_share` card. The boundary is the system share sheet.
@Suite("Share action", .serialized, .tags(.actions, .integration))
@MainActor
struct ShareActionTests {

    @Test("tapping a button authored with share opens the share sheet with its text")
    func shareOpensTheShareSheet() async throws {
        let sdk = try await SdkHarness.start(
            loadCampaign("actions/action_share.json"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver("test_action_share")

        try await sdk.tap(id: SdkHarness.buttonId)

        try await sdk.waitUntil("the share sheet is asked for") { !sdk.platform.shared.isEmpty }
        #expect(sdk.platform.shared == ["Get 20% off with code SAVE20"])
    }
}
}
