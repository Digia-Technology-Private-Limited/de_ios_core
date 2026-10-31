import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// Legacy (pre-canvas) nudges the SDK must refuse before anything is drawn: a `templateConfig.layout`
/// column tree with no `layoutMode`, parsed by `NudgeParser`. Fixture: `legacy_nudge/legacy_nudge_dialog`,
/// edited in the test. Showing and closing a legacy nudge is the sample app's `LegacyNudgeBehaviourTests`.
///
/// iOS only: Flutter no longer reads this shape, so there is no Flutter test to port.
@Suite("Legacy nudge (column tree): rejected shapes", .serialized, .tags(.integration, .behaviour, .nudge))
@MainActor
struct LegacyNudgeBehaviourTests {

    private static let dialogKey = "test_legacy_nudge_dialog"
    private static let dialogTitle = "Hi Asha, your reward is ready"

    // Fails if the `guard ... != .fullScreen` in `NudgeConfig.fromJson`'s legacy branch is removed:
    // a full screen with no canvas would be stored and shown with nothing to draw it.
    @Test("a legacy full-screen nudge is rejected at parse and never shows")
    func legacyFullScreenIsRejected() async throws {
        let campaign = try legacyFixture("legacy_nudge/legacy_nudge_dialog") { config in
            var container = config["container"] as? [String: Any] ?? [:]
            container["displayType"] = "full_screen"
            config["container"] = container
        }
        let sdk = try await SdkHarness.legacyStart([campaign])
        defer { sdk.tearDown() }

        let presentation = try sdk.deliver(Self.dialogKey, variables: ["first_name": "Asha"])
        try await sdk.waitUntil("the delivery settled") { presentation.outcome.settledValue != nil }

        #expect(presentation.dropReason == .unknownCampaignKey)
        #expect(sdk.sdk.controller.activeNudge == nil)
        #expect(!sdk.isShowing(Self.dialogTitle))
    }
}
}
