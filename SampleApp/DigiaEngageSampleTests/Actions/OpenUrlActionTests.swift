import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `openUrl`: the Test Kit's `canvas-button-fill` card, unchanged, whose button is authored
/// `Action.openUrl` with `launchMode: externalApplication`.
///
/// iOS has no launch-mode distinction: an external URL and a deep link both end in
/// `UIApplication.open(url)` with no options (Flutter passes `externalApplication` vs
/// `platformDefault`). So this pins the URL handed to iOS, not a mode.
@Suite("OpenUrl action", .serialized, .tags(.actions, .integration))
@MainActor
struct OpenUrlActionTests {

    @Test("tapping a button authored with openUrl hands that URL to iOS")
    func openUrlOpensTheAuthoredUrl() async throws {
        let sdk = try await ActionHarness.start(ActionCampaigns.load("canvas", "canvas-button-fill"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(ActionHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver(ActionHarness.buttonCampaignKey)

        try await sdk.tap(id: ActionHarness.buttonId)

        try await sdk.waitUntil("the URL is opened") { !sdk.platform.opened.isEmpty }
        #expect(sdk.platform.opened == ["https://digia.com/claim"])
    }
}
}
