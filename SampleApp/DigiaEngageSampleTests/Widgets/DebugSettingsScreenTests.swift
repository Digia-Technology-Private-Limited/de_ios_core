import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// The debug settings screen (`DigiaDebugSettingsView`) opened over a running app, driven with
/// real touches. The switches, rows and labels moved to the shared YAML suite
/// (`tests/debug/`, category issue #239); what stays here cannot be reached
/// from YAML, each labelled why.
///
/// Port of `flutter/core/test/digia_debug_settings_screen_test.dart`. Not ported: "live testing is
/// not offered before the SDK has been initialized" — iOS has no such state, the row always shows
/// and the switch persists before init (`LiveTestService.setEnabled`); "saved by the keyboard's
/// done key" — the iOS editor has no submit action, only Save and Cancel.
@Suite("Debug settings screen", .serialized, .tags(.integration, .debug, .registry))
@MainActor
struct DebugSettingsScreenTests {

    private var overlay: DigiaDebugOverlayController { SDKInstance.shared.debugOverlayControllerSnapshot() }
    private var liveTest: LiveTestService { SDKInstance.shared.liveTestServiceSnapshot() }

    /// A wrapper that cannot capture, so the screen offers Sync.
    private func boot() async throws -> SdkHarness {
        let sdk = try await SdkHarness.widgetsBoot(wrapperBinding: "unsupported_wrapper")
        try await sdk.widgetsOpenSettings()
        return sdk
    }

    // The bubble switch itself moved to the shared YAML suite
    // (`tests/debug/debug_bubble_switch.yaml`).
    // not converted: not SDK-observable from a test — reading the overlay
    // flag needs the driver's snapshot, and YAML text matching cannot tell
    // the floating bubble ("Digia") apart from its settings row
    // ("Digia bubble").
    @Test("tapping anywhere on the bubble row toggles it, there being no screen behind it")
    func bubbleRowToggles() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }

        try await sdk.widgetsTap(exactly: "Digia bubble") { self.overlay.isVisible }

        try await sdk.widgetsTap(exactly: "Digia bubble") { !self.overlay.isVisible }
        #expect(!WidgetsDebugState.stored("debug.overlay_visible"))
    }

    // MARK: - Device name

    /// The device-name row is a `Button` with `.buttonStyle(.plain)` whose label is a VStack, a
    /// `Spacer` and the pencil: a plain button is hit only where it draws, so with a short name the
    /// middle of the row (the spacer) takes no touch. Flutter's `ListTile` opens the editor from
    /// anywhere on the row.
    // not converted: known bug Digia-Technology-Private-Limited/de_ios_core#306 —
    // tapping the middle needs a coordinate tap, which YAML has no frame query for.
    // Fails if (once fixed): DigiaDebugSettingsView.swift's device-name label loses its
    // `.contentShape(Rectangle())`.
    @Test("tapping the middle of the device-name row opens the editor")
    func deviceNameRowWholeWidth() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        liveTest.setDeviceName("Kiosk 4")
        try await sdk.widgetsTap(row: "Live testing") { sdk.isShowing("Device ID") }

        let row = try await sdk.widgetsSteadyFrame("the device-name row") { sdk.widgetsRowFrames("Device name").first }
        try TouchSynthesizer.tap(at: CGPoint(x: row.midX, y: row.midY), in: try #require(sdk.window))
        await withKnownIssue("The device-name row takes touches only on its text and icon (DigiaDebugSettingsView.swift)") {
            try await sdk.waitUntil("the editor", timeout: 2) {
                sdk.widgetsIsShowing(exactly: "Shown in the dashboard device list.")
            }
        }
    }
}
}
