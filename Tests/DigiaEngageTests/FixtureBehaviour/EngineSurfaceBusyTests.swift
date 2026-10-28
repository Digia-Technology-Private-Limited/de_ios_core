import SwiftUI
import Testing
@testable import DigiaEngage

extension RenderedUITests {
/// A nudge on screen owns the surface: the next nudge is turned away, not stacked on top and not
/// swapped in. Fixtures: `engine_surface_busy_first` / `engine_surface_busy_second`.
/// Port of `flutter/core/test/fixture_behaviour/engine_surface_busy_test.dart`.
@Suite("Engine: surface busy", .serialized, .tags(.integration, .behaviour, .surface))
@MainActor
struct EngineSurfaceBusyTests {

    private func boot() async throws -> (SdkHarness, first: String, second: String) {
        let first = try fixture("engine/engine_surface_busy_first")
        let second = try fixture("engine/engine_surface_busy_second")
        let sdk = try await SdkHarness.start(campaigns: [first, second])
        try sdk.mount { Text("host app") }
        return (sdk, keyOf(first), keyOf(second))
    }

    // Fails if a nudge over a nudge stops being `.busy` in `SurfaceRule.swift`.
    @Test("a second nudge is dropped as surface_busy and the first stays")
    func secondNudgeIsTurnedAway() async throws {
        let (sdk, first, second) = try await boot()
        defer { sdk.tearDown() }
        try sdk.deliver(first)
        try await sdk.waitUntil("the first nudge is up") { sdk.isShowing("First Nudge Holds The Surface") }

        let turnedAway = try sdk.deliver(second)
        try await sdk.settle()

        #expect(turnedAway.dropReason == .surfaceBusy)
        #expect(!sdk.isShowing("Second Nudge Must Not Show"))
        #expect(sdk.isShowing("First Nudge Holds The Surface"))
        #expect(SDKInstance.shared.controller.activeNudge?.payload.campaignKey == first)
    }

    // Same line: the redelivered campaign meets its own showing as the blocker.
    @Test("the same nudge delivered again while up is dropped, not doubled")
    func sameNudgeAgainIsDropped() async throws {
        let (sdk, first, _) = try await boot()
        defer { sdk.tearDown() }
        try sdk.deliver(first)
        try await sdk.waitUntil("the first nudge is up") { sdk.isShowing("First Nudge Holds The Surface") }

        let again = try sdk.deliver(first)
        try await sdk.settle()

        #expect(again.dropReason == .surfaceBusy)
        #expect(sdk.isShowing("First Nudge Holds The Surface"))
    }

    // Fails if the nudge's close action stops releasing the surface: `dismissNudge()` no longer
    // clears `activeNudge` in `DigiaOverlayController.swift`.
    @Test("once the first is closed the second can take the surface")
    func closingReleasesTheSurface() async throws {
        let (sdk, first, second) = try await boot()
        defer { sdk.tearDown() }
        try sdk.deliver(first)
        try await sdk.waitUntil("the first nudge is up") { sdk.isShowing("First Nudge Holds The Surface") }
        try await sdk.activate(id: "button")
        try await sdk.waitUntil("the first nudge is gone") { sdk.sdk.controller.activeNudge == nil }

        let admitted = try sdk.deliver(second)
        try await sdk.waitUntil("the second nudge is up") {
            sdk.sdk.controller.activeNudge?.payload.campaignKey == second
        }

        #expect(admitted.dropReason == nil)
    }
}
}
