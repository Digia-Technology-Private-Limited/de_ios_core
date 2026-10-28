import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A campaign limited to screens only shows on them, and a sloppy screen list degrades to the
/// names it got right. Fixture: `engine_screen_list_messy` —
/// `["  home  ", "", "home", 42, null, "   ", "cart"]`.
/// Port of `flutter/core/test/fixture_behaviour/engine_screen_targeting_test.dart`.
@Suite("Engine: screen targeting", .serialized, .tags(.integration, .behaviour, .surface))
@MainActor
struct EngineScreenTargetingTests {

    private func boot() async throws -> (SdkHarness, key: String) {
        let campaign = try fixture("engine/engine_screen_list_messy")
        let sdk = try await SdkHarness.start(campaign)
        try sdk.mount { Text("host app") }
        return (sdk, keyOf(campaign))
    }

    // Fails if a non-string entry is no longer skipped when the screen list is parsed in
    // `campaign_model.swift`: the campaign is dropped from the bundle and neither screen shows it.
    @Test("shows on each real name in the list, home and cart")
    func showsOnEachRealName() async throws {
        let (sdk, key) = try await boot()
        defer { sdk.tearDown() }

        for screen in ["home", "cart"] {
            sdk.setCurrentScreen(screen)
            let delivery = try sdk.deliver(key)
            try await sdk.waitUntil("the nudge is up on \(screen)") { sdk.isShowing("Home And Cart Only") }
            #expect(delivery.dropReason == nil, "on \(screen)")

            try await sdk.activate(id: "button")
            try await sdk.waitUntil("the nudge is gone on \(screen)") { sdk.sdk.controller.activeNudge == nil }
        }
    }

    // Fails if the screen gate stops excluding other screens, including the no-screen case.
    @Test("is dropped as screen_not_targeted anywhere else: no screen, another screen, and screens named like the stray entries")
    func droppedEverywhereElse() async throws {
        let (sdk, key) = try await boot()
        defer { sdk.tearDown() }

        // `setCurrentScreen` trims and turns a blank name into "no screen".
        for screen in ["", "   ", "brands", "42", "null"] {
            sdk.setCurrentScreen(screen)
            let delivery = try sdk.deliver(key)
            try await sdk.settle(0.1)

            #expect(delivery.dropReason == .screenNotTargeted, "on \"\(screen)\"")
        }
        #expect(!sdk.isShowing("Home And Cart Only"))
    }
}
}
