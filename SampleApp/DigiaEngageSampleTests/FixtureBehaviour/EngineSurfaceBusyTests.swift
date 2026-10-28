// tags: widget nudge
import SwiftUI
import Testing
import UIKit

@testable import DigiaEngage

/// A nudge on screen owns the surface: the next nudge is turned away, not stacked on top and not swapped in.
/// Fixtures: `engine_surface_busy_first` / `engine_surface_busy_second`.
@MainActor
@Suite("engine surface busy", .serialized, .tags(.integration, .behaviour, .surface))
struct EngineSurfaceBusyTests {
    private let first = WorkspaceFixtures.campaign("campaigns/engine/engine_surface_busy_first.json")
    private let second = WorkspaceFixtures.campaign("campaigns/engine/engine_surface_busy_second.json")

    // Fails if a nudge over a nudge stops being busy in `SurfaceRule`.
    @Test("a second nudge is dropped as surface_busy and the first stays")
    func secondNudgeTurnedAway() async throws {
        let sdk = try await SdkHarness.start([first, second]) { Color.clear }
        defer { sdk.tearDown() }
        sdk.cep.deliver(first.campaignKey)
        try try await sdk.settle(1)
        #expect(UIProbe.texts(in: sdk.window).contains("First Nudge Holds The Surface"))

        let turnedAway = try #require(sdk.cep.deliver(second.campaignKey))
        try try await sdk.settle(1)

        // A peek, not an await: a nudge that is shown never settles, and the test must fail, not wait.
        guard case .dropped(let reason, _) = turnedAway.outcome.settledValue else {
            Issue.record("the second nudge was not dropped: \(String(describing: turnedAway.outcome.settledValue))")
            return
        }
        #expect(reason == .surfaceBusy)
        let texts = UIProbe.texts(in: sdk.window)
        #expect(!texts.contains("Second Nudge Must Not Show"))
        #expect(texts.contains("First Nudge Holds The Surface"))
    }

    // Same line: the redelivered campaign meets its own showing as the blocker.
    @Test("the same nudge delivered again while up is dropped, not doubled")
    func sameNudgeAgain() async throws {
        let sdk = try await SdkHarness.start([first, second]) { Color.clear }
        defer { sdk.tearDown() }
        sdk.cep.deliver(first.campaignKey)
        try try await sdk.settle(1)

        let again = try #require(sdk.cep.deliver(first.campaignKey))
        try try await sdk.settle(1)

        guard case .dropped(let reason, _) = again.outcome.settledValue else {
            Issue.record("the redelivered nudge was not dropped")
            return
        }
        #expect(reason == .surfaceBusy)
        #expect(UIProbe.texts(in: sdk.window).filter { $0 == "First Nudge Holds The Surface" }.count == 1)
    }
}
