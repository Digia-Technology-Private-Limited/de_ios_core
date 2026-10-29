// tags: widget floater pip campaign_behaviour
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

extension RenderedUITests {
/// Every way a PiP or story floater ends and the exact chain it sends. Both float over the app, so the CEP's
/// hold comes back at the impression while they keep running. The cases that need a real touch run hosted, in
/// `SampleApp/DigiaEngageSampleTests/CampaignBehaviour/FloaterCampaignBehaviourTests.swift`.
///
/// The chrome's glyph buttons carry no accessibility label, so a test tells them apart by the fixed corner
/// each sits in; the touch on them is still a real one.
///
/// platform note: the Dart twin is `test/campaign_behaviour/floating_campaign_behaviour_test.dart`.
@MainActor
@Suite("Floater campaign behaviour", .serialized, .tags(.integration, .floater, .pip, .analytics))
struct FloaterCampaignBehaviourTests {
    private func fixture(_ path: String) -> WorkspaceFixtures.Campaign { WorkspaceFixtures.campaign(path) }

    private func start(_ path: String) async throws -> SdkHarness {
        try await SdkHarness.startChain([fixture(path)]) { Text("App home") }
    }

    /// Waits for the floater's impression: a PiP shows only once its media has loaded.
    private func show(_ sdk: SdkHarness, _ d: Delivery) async throws {
        try await sdk.waitUntil("the floater's impression", timeout: 5) { d.displayed }
        try await sdk.settle(1)
    }

    // MARK: - PiP

    @Test("pip: auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func pipAutoDismiss() async throws {
        let key = "test_pip_auto_dismiss"
        let sdk = try await start("campaigns/pip/pip_auto_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The fixture's autoDismissAfterMs is 3000.
        try await sdk.waitUntil("the PiP has timed out", timeout: 5) {
            SDKInstance.shared.floaterOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .autoTimeout,
            hold: .floating)
    }

    @Test("pip: leaving its screen: dismissed as screen_exit")
    func pipLeavingItsScreen() async throws {
        let key = "test_pip_screen_change_home_only"
        let sdk = try await start("campaigns/pip/pip_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.setCurrentScreen(name: "search")
        try await sdk.settle()

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .screenExit,
            hold: .floating)
    }

    @Test("pip: off its target screen: screen_not_targeted")
    func pipOffTargetScreen() async throws {
        let key = "test_pip_screen_change_home_only"
        let sdk = try await start("campaigns/pip/pip_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.5)

        expectDropped(await sdk.sent(key), d, .screenNotTargeted)
    }

    // MARK: - Story floater

    @Test("story floater: auto-dismiss: dismissed as auto_timeout", .tags(.slow))
    func storyAutoDismiss() async throws {
        let key = "test_floater_auto_dismiss"
        let sdk = try await start("campaigns/floater/floater_auto_dismiss.json")
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        // The fixture's autoDismissAfterMs is 3000.
        try await sdk.waitUntil("the floater has timed out", timeout: 5) {
            SDKInstance.shared.floaterStoryOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .autoTimeout,
            hold: .floating)
    }

    @Test("story floater: leaving its screen: dismissed as screen_exit")
    func storyLeavingItsScreen() async throws {
        let key = "test_floater_story_screen_change_home_only"
        let sdk = try await start("campaigns/floater/floater_story_screen_change_home_only.json")
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "home")
        let d = try sdk.deliverChain(key)
        try await show(sdk, d)

        Digia.setCurrentScreen(name: "search")
        // The window fades out before its state clears; wait for that rather than a fixed delay
        // the same length as the fade.
        try await sdk.waitUntil("the story floater is gone") {
            SDKInstance.shared.floaterStoryOrchestrator.state == nil
        }

        expectChain(
            await sdk.sent(key), d, names: [Chain.triggered, Chain.viewed, Chain.dismissed], reason: .screenExit,
            hold: .floating)
    }

    // MARK: - Dropped

    @Test("pip: CEP cancel before it shows: cancelled")
    func pipCepCancelBeforeShowing() async throws {
        let key = "test_pip_close_dismiss"
        let campaign = fixture("campaigns/pip/pip_close_dismiss.json")
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        d.presentation.cancel()
        try await sdk.settle(2)
        #expect(SDKInstance.shared.floaterOrchestrator.state == nil)
        #expect(!d.displayed)

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil,
            extras: ["cancel_cause": "cep_cancel"], detail: "ended before it displayed (cancelled)")
    }

    @Test("story floater: off its target screen: screen_not_targeted")
    func storyOffTargetScreen() async throws {
        let key = "test_floater_story_screen_change_home_only"
        let campaign = fixture("campaigns/floater/floater_story_screen_change_home_only.json")
        let sdk = try await SdkHarness.startChain([campaign]) { Text("App home") }
        defer { sdk.tearDown() }
        Digia.setCurrentScreen(name: "search")
        let d = try sdk.deliverChain(key)
        try await sdk.settle(1.5)

        expectDroppedWire(
            await sdk.sent(key), d, .screenNotTargeted, campaign, screen: "search",
            extras: ["target_screens": ["home"]], detail: "currentScreen=search targetScreenNames=[\"home\"]")
    }

    // As coded: the image answers 404, so the PiP has no media to float; its window never opens, and the media
    // end it reports reaches the CEP as a cancel (`cancelled`), with the media end as the cause.
    @Test("pip: its image fails to load: dropped as cancelled, as coded")
    func pipMediaFailsToLoad() async throws {
        let key = "test_pip_close_dismiss"
        let base = fixture("campaigns/pip/pip_close_dismiss.json")
        var json = base.json
        var template = try #require(json["templateConfig"] as? [String: any Sendable])
        var media = try #require(template["media"] as? [String: any Sendable])
        media["url"] = "https://images.example.test/missing.jpg"
        template["media"] = media
        json["templateConfig"] = template
        let campaign = WorkspaceFixtures.Campaign(name: base.name, json: json)
        let sdk = try await SdkHarness.startChain(
            [campaign], backend: StubBackend.Options(foreignImagesAsStandIn: false)
        ) { Text("App home") }
        defer { sdk.tearDown() }
        let d = try sdk.deliverChain(key)
        try await sdk.waitUntil("the PiP gives up", timeout: 15) { d.outcome != nil }
        #expect(SDKInstance.shared.floaterOrchestrator.state == nil)
        #expect(!d.displayed)

        expectDroppedWire(
            await sdk.sent(key), d, .cancelled, campaign, screen: nil, extras: ["cancel_cause": "auto_timeout"],
            detail: "ended before it displayed (auto_timeout)")
    }
}
}
