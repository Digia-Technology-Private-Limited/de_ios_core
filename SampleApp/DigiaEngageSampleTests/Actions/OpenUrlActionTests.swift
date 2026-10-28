import SwiftUI
import Testing
@testable import DigiaEngage

extension HostedUITests {
/// `openUrl`: the `actions/fixtures/action_open_url` card, whose button is authored
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
        let sdk = try await SdkHarness.start(
            loadCampaign("actions/action_open_url.json"))
        defer { sdk.tearDown() }
        try sdk.mount { DigiaSlot(SdkHarness.buttonSlotKey) { EmptyView() } }
        try sdk.deliver("test_action_open_url")

        try await sdk.tap(id: SdkHarness.buttonId)

        try await sdk.waitUntil("the URL is opened") { !sdk.platform.opened.isEmpty }
        #expect(sdk.platform.opened == ["https://www.digia.tech"])
    }
}
}
