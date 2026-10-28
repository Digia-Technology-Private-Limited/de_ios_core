import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// Page & component capture, offered only to the React Native binding
/// (`SDKInstance.isCaptureSupported`): its switch on the debug settings, its own screen
/// (`DigiaRecordedSessionScreen`) with the capture profile, and the bubble's capture button. Real
/// touches throughout; the boundary is the capture upload, answered by the mock network.
///
/// Port of the recording cases of `flutter/core/test/digia_debug_settings_screen_test.dart`
/// ("tapping the switch toggles recording without navigating", "tapping the row title opens the
/// recorded-session list", "turning recording on also enables the Digia bubble toggle"), which
/// Flutter runs as capture; and of iOS's own capture affordances, which have no Flutter widget test.
@Suite("Capture settings", .serialized, .tags(.integration, .debug, .capture))
@MainActor
struct CaptureSettingsScreenTests {

    private var sdkInstance: SDKInstance { SDKInstance.shared }
    private var registry: ComponentRegistryService { SDKInstance.shared.componentRegistrySnapshot() }

    private func boot() async throws -> SdkHarness {
        try await SdkHarness.widgetsBoot(reactNative: true)
    }

    // Fails if: DigiaDebugSettingsView.swift stops offering the capture row when
    // `instance.isCaptureSupported`, or SDKInstance.swift `setCaptureModeEnabled` stops persisting
    // it, turning recording on, or showing the bubble.
    @Test("the capture switch turns capture on without leaving the screen, keeps it on disk, and shows the bubble with a capture button")
    func captureSwitch() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        try await sdk.widgetsOpenSettings()
        #expect(sdk.widgetsRowFrames("Sync").isEmpty, "capture replaces Sync")

        try await sdk.widgetsTapSwitch(row: "Page & component capture") { self.sdkInstance.captureModeEnabled }

        #expect(WidgetsDebugState.stored("capture.enabled"))
        #expect(registry.isEnabled)
        #expect(sdkInstance.debugOverlayControllerSnapshot().isVisible)
        #expect(!sdk.isShowing("Restart recommended"), "only Sync warns about already-mounted screens")
        #expect(!sdk.isShowing("Capture profile"), "the switch does not open the capture screen")

        try await sdk.widgetsCloseSettings()
        try await sdk.waitUntil("the capture button on the bubble") { sdk.widgetsIsShowing(exactly: "Capture current page") }
    }

    // Fails if: DigiaRecordedSessionScreen.swift binds a profile switch to the wrong
    // `setCaptureProfile` argument, or SDKInstance.swift `setCaptureProfile` stops persisting it.
    @Test("the capture title opens the capture screen, whose profile switches each keep their own setting")
    func captureScreenProfile() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        try await sdk.widgetsOpenSettings()

        try await sdk.widgetsTap(row: "Page & component capture") {
            sdk.isShowing("Interactive elements and their required structure are always included.")
        }
        #expect(!sdkInstance.captureModeEnabled, "the title does not flip capture")

        try await sdk.widgetsTapSwitch(row: "Include text nodes") { self.sdkInstance.captureTextEnabled }
        #expect(WidgetsDebugState.stored("capture.include_text"))
        #expect(!sdkInstance.captureMediaEnabled && !sdkInstance.captureStructureEnabled)

        try await sdk.widgetsTapSwitch(row: "Include images and media") { self.sdkInstance.captureMediaEnabled }
        #expect(WidgetsDebugState.stored("capture.include_media"))
        #expect(!sdkInstance.captureStructureEnabled)

        try await sdk.widgetsTapSwitch(row: "Include other structural nodes") { self.sdkInstance.captureStructureEnabled }
        #expect(WidgetsDebugState.stored("capture.include_structure"))

        try await sdk.widgetsTapSwitch(row: "Include text nodes") { !self.sdkInstance.captureTextEnabled }
        #expect(!WidgetsDebugState.stored("capture.include_text"))
        #expect(sdkInstance.captureMediaEnabled && sdkInstance.captureStructureEnabled)

        // The capture screen has the capture switch too.
        try await sdk.widgetsTapSwitch(row: "Page & component capture") { self.sdkInstance.captureModeEnabled }
    }

    // Fails if: SDKInstance.swift `captureCurrentPage` stops appending the accepted page to
    // `capturedPages`, or DigiaRecordedSessionScreen.swift stops listing `instance.capturedPages`.
    @Test("the bubble's capture button uploads the page, says so, and the capture screen lists it")
    func captureFromTheBubble() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        let page = "widgets_capture_home"
        sdk.network.enqueueResponse(
            url: DigiaEndpoints.recordPageCapture, statusCode: 200,
            body: #"{"data":{"response":{"assetId":"asset-widgets"}}}"#)
        sdkInstance.setCaptureModeEnabled(true)
        sdk.setCurrentScreen(page)

        try await sdk.widgetsTap(exactly: "Capture current page") { self.sdkInstance.captureStatusMessage != nil }

        try await sdk.waitUntil("the capture to upload", timeout: 8) {
            self.sdkInstance.capturedPages.contains { $0.pageKey == page }
        }
        #expect(sdkInstance.capturedPages.first { $0.pageKey == page }?.assetId == "asset-widgets")
        #expect(sdkInstance.captureStatusMessage == "Captured \(page)")
        try await sdk.waitUntil("the bubble back after the capture") { sdk.widgetsIsShowing(exactly: "Digia") }
        // The confirmation is published while the bubble is hidden for the screenshot, and the
        // bubble owns the alert: back on screen, its `.onChange(of: captureStatusMessage)` has
        // nothing to change from, so the alert never opens (and the message is never cleared).
        // Flutter and Android confirm the capture.
        await withKnownIssue("A successful capture's \"Captured <page>\" confirmation never shows (RecordingBadgeView.swift)") {
            try await sdk.waitUntil("the confirmation", timeout: 2) { sdk.isShowing("Captured \(page)") }
        }
        sdkInstance.clearCaptureStatus()

        try await sdk.widgetsOpenSettings()
        try await sdk.widgetsTap(row: "Page & component capture") {
            sdk.isShowing("Interactive elements and their required structure are always included.")
        }
        // Listed twice: detected (the page was recorded when it was reported) and uploaded.
        try await sdk.waitUntil("the page in both lists") { sdk.widgetsFrames(exactly: page).count >= 2 }
        #expect(!sdk.isShowing("No page captures uploaded yet."))
    }

    // Fails if: SDKInstance.swift `captureCurrentPage` stops guarding on `_currentScreen` (it
    // would upload a capture with no page key).
    @Test("capturing with no screen reported says it cannot, and uploads nothing")
    func captureWithoutScreen() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        sdkInstance.setCaptureModeEnabled(true)
        sdk.setCurrentScreen("")

        try await sdk.widgetsTap(exactly: "Capture current page") { self.sdkInstance.captureStatusMessage != nil }

        try await sdk.waitUntil("the explanation") {
            sdk.isShowing("Capture unavailable — current screen or app window is unavailable")
        }
        #expect(sdk.network.recordedMultipartRequests.isEmpty)
        try await sdk.widgetsTap(exactly: "OK") { self.sdkInstance.captureStatusMessage == nil }
    }
}
}
