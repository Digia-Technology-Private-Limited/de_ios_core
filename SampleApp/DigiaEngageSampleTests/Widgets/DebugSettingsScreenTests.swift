import SwiftUI
import Testing
import UIKit
@testable import DigiaEngage

extension HostedUITests {
/// The debug settings screen (`DigiaDebugSettingsView`) opened over a running app, driven with
/// real touches: each switch is tapped where a finger would tap it, and the proof is what the SDK
/// then keeps (its in-memory flag and the value on disk) and what the screen shows next.
///
/// A native app is offered Sync; only the React Native binding is offered page capture (see
/// `CaptureSettingsScreenTests`).
///
/// Port of `flutter/core/test/digia_debug_settings_screen_test.dart`. Not ported: "live testing is
/// not offered before the SDK has been initialized" — iOS has no such state, the row always shows
/// and the switch persists before init (`LiveTestService.setEnabled`); "saved by the keyboard's
/// done key" — the iOS editor has no submit action, only Save and Cancel.
@Suite("Debug settings screen", .serialized, .tags(.integration, .debug, .registry))
@MainActor
struct DebugSettingsScreenTests {

    private var registry: ComponentRegistryService { SDKInstance.shared.componentRegistrySnapshot() }
    private var overlay: DigiaDebugOverlayController { SDKInstance.shared.debugOverlayControllerSnapshot() }
    private var liveTest: LiveTestService { SDKInstance.shared.liveTestServiceSnapshot() }

    private func boot() async throws -> SdkHarness {
        let sdk = try await SdkHarness.widgetsBoot()
        try await sdk.widgetsOpenSettings()
        return sdk
    }

    // Fails if: SettingsToggleRow.swift puts the switch inside the row's `Button(action: onTap)`
    // (the tap would open the synced list instead of flipping Sync), or
    // ComponentRegistryService.swift `setEnabled` stops calling `debugOverlay.setVisible(true)`.
    @Test("tapping the Sync switch turns syncing on without leaving the screen, and shows the bubble")
    func syncSwitchTogglesWithoutNavigating() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        #expect(!registry.isEnabled)
        #expect(!overlay.isVisible)

        try await sdk.widgetsTapSwitch(row: "Sync") { self.registry.isEnabled }

        #expect(WidgetsDebugState.stored("registry.recording_enabled"))
        #expect(overlay.isVisible, "turning Sync on turns the bubble on")
        #expect(WidgetsDebugState.stored("debug.overlay_visible"))
        // Already-mounted screens are not recorded retroactively; the screen says so.
        try await sdk.waitUntil("the restart hint") { sdk.isShowing("Restart recommended") }
        #expect(!sdk.isShowing("Nothing synced yet this session."), "the switch does not open the list")
    }

    // Fails if: DigiaDebugSettingsView.swift's Sync row loses `onTap: { showSession = true }`.
    @Test("tapping the Sync title opens the synced-this-session list and leaves Sync off")
    func syncTitleOpensSessionList() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }

        try await sdk.widgetsTap(row: "Sync") { sdk.widgetsIsShowing(exactly: "Synced This Session") }

        #expect(!registry.isEnabled)
    }

    // Fails if: DigiaRecordedSessionScreen.swift stops listing `registry.recordedThisSession`
    // (or drops an entry's `screen:` line), or DigiaSlot.swift stops calling `recordSlotSeen` in
    // its init.
    @Test("the synced list shows each page and slot recorded this session, with the screen it was on")
    func syncedListShowsRecords() async throws {
        let sdk = try await SdkHarness.widgetsBoot()
        defer { sdk.widgetsFinish() }
        registry.setEnabled(true)
        sdk.setCurrentScreen("widgets_list_home")
        _ = DigiaSlot("widgets_list_slot")
        try await sdk.widgetsOpenSettings()

        try await sdk.widgetsTap(row: "Sync") { sdk.widgetsIsShowing(exactly: "widgets_list_slot") }

        #expect(sdk.widgetsIsShowing(exactly: "widgets_list_home"))
        #expect(sdk.widgetsIsShowing(exactly: "screen: widgets_list_home"), "the slot names its screen")
        #expect(!sdk.isShowing("Nothing synced yet this session."))
        let count = registry.recordedThisSession.count
        #expect(sdk.isShowing("Synced Keys (\(count))") || sdk.isShowing("SYNCED KEYS (\(count))"))
    }

    // Fails if: DigiaDebugSettingsView.swift's bubble row binds to anything but
    // `overlay.setVisible`, or DigiaDebugOverlayController.swift stops persisting it.
    @Test("the bubble switch flips the bubble alone, and the bubble then shows over the app")
    func bubbleSwitchIsIndependentOfSync() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }

        try await sdk.widgetsTapSwitch(row: "Digia bubble") { self.overlay.isVisible }

        #expect(WidgetsDebugState.stored("debug.overlay_visible"))
        #expect(!registry.isEnabled, "the bubble does not turn Sync on")
        try await sdk.widgetsCloseSettings()
        try await sdk.waitUntil("the bubble over the app") { sdk.widgetsIsShowing(exactly: "Digia") }
        #expect(Digia.debugBadgeFrame != nil)
    }

    // Fails if: SettingsToggleRow.swift drops `.onTapGesture { isOn.toggle() }` from the row
    // without an L2 screen.
    @Test("tapping anywhere on the bubble row toggles it, there being no screen behind it")
    func bubbleRowToggles() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }

        try await sdk.widgetsTap(exactly: "Digia bubble") { self.overlay.isVisible }

        try await sdk.widgetsTap(exactly: "Digia bubble") { !self.overlay.isVisible }
        #expect(!WidgetsDebugState.stored("debug.overlay_visible"))
    }

    // Fails if: DigiaDebugSettingsView.swift's first row stops linking to
    // `DigiaCampaignTimelineView()`.
    @Test("the Campaign timeline row opens the timeline")
    func timelineRowOpensTimeline() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        let subtitle = "What Digia did with your campaigns, newest first."
        #expect(sdk.isShowing(subtitle))
        ScreenSink.shared.clear()

        try await sdk.widgetsTap(row: "Campaign timeline") { sdk.isShowing("Nothing recorded yet.") }
    }

    // MARK: - Live testing

    // Fails if: DigiaDebugSettingsView.swift `LiveTestConnectionState.label` stops returning
    // "Off" while disabled whatever the connection (`guard enabled else { return "Off" }`), or
    // maps a state to the wrong words.
    @Test("live testing says Off, then where its connection stands once switched on, then Off again")
    func liveTestingLabelFollowsConnection() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        let stream = try WidgetsLiveStreamNetwork.install(over: sdk)
        #expect(sdk.widgetsIsShowing(exactly: "Live testing, Off"))
        #expect(!liveTest.isEnabled)

        try await sdk.widgetsTapSwitch(row: "Live testing") { self.liveTest.isEnabled }

        #expect(WidgetsDebugState.stored("live_test.enabled"))
        try await sdk.waitUntil("Connecting…") { sdk.widgetsIsShowing(exactly: "Live testing, Connecting…") }
        #expect(stream.opened.count == 1, "switching on opens the live-test stream")
        #expect(stream.opened.first?.url.path == URL(string: DigiaEndpoints.liveTestConnect)?.path)

        stream.emit(SseEvent(event: "connected", data: #"{"deviceId":"d"}"#))
        try await sdk.waitUntil("Connected") {
            sdk.widgetsIsShowing(exactly: "Live testing, Connected — visible on the dashboard")
        }

        stream.emit(SseEvent(event: "error", data: #"{"message":"boom"}"#))
        try await sdk.waitUntil("the error") {
            sdk.widgetsIsShowing(exactly: "Live testing, Connection error — retrying…")
        }

        try await sdk.widgetsTapSwitch(row: "Live testing") { !self.liveTest.isEnabled }
        try await sdk.waitUntil("Off whatever the connection was") { sdk.widgetsIsShowing(exactly: "Live testing, Off") }
        #expect(!WidgetsDebugState.stored("live_test.enabled"))
    }

    // Fails if: DigiaDebugSettingsView.swift `label` drops the `deviceName.map { "Connected as \($0)" }`.
    @Test("a connected device with a name is said to be connected as that name")
    func liveTestingConnectedAsName() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        liveTest.setDeviceName("Lobby iPad")

        let stream = try WidgetsLiveStreamNetwork.install(over: sdk)

        try await sdk.widgetsTapSwitch(row: "Live testing") { self.liveTest.isEnabled }
        try await sdk.waitUntil("the stream open") { !stream.opened.isEmpty }
        stream.emit(SseEvent(event: "connected", data: "{}"))

        try await sdk.waitUntil("Connected as") { sdk.widgetsIsShowing(exactly: "Live testing, Connected as Lobby iPad") }
    }

    // Fails if: DigiaDebugSettingsView.swift's Live testing row loses
    // `onTap: { showLiveTesting = true }`, or `LiveTestingDetailsScreen` stops showing the device id.
    @Test("live testing has a details screen with the device name and ID, and its own switch")
    func liveTestingDetails() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }

        try await sdk.widgetsTap(row: "Live testing") { sdk.isShowing("Device ID") }

        #expect(sdk.isShowing("Device name"))
        #expect(sdk.widgetsIsShowing(exactly: "Device name, Not set — using the device model"))
        let deviceId = try #require(liveTest.deviceId)
        #expect(!deviceId.isEmpty)
        #expect(sdk.widgetsIsShowing(exactly: deviceId))

        try await sdk.widgetsTapSwitch(row: "Live testing") { self.liveTest.isEnabled }
    }

    // MARK: - Device name

    /// Opens the device-name editor from the live-testing details screen.
    private func openEditor(_ sdk: SdkHarness) async throws -> UITextField {
        try await sdk.widgetsTap(row: "Live testing") { sdk.isShowing("Device ID") }
        try await sdk.widgetsTap(rowTitle: "Device name") { sdk.widgetsIsShowing(exactly: "Shown in the dashboard device list.") }
        let window = try #require(sdk.window)
        var field: UITextField?
        SdkHarness.widgetsCollect(in: window, where: { $0 is UITextField }) { field = field ?? ($0 as? UITextField) }
        return try #require(field)
    }

    /// Replaces what the field holds the way typing does, through the keyboard input protocol.
    private func type(_ text: String, into field: UITextField, _ sdk: SdkHarness) async throws {
        field.becomeFirstResponder()
        field.selectAll(nil)
        field.deleteBackward()
        while field.hasText { field.deleteBackward() }
        field.insertText(text)
        try await sdk.settle(0.3)
    }

    // Fails if: LiveTestService.swift `normalizeDeviceName` stops trimming, or
    // DigiaDebugSettingsView.swift's Save stops calling `liveTest.setDeviceName(deviceName)`.
    @Test("a device name is saved from the editor, trimmed, kept on disk, and shown")
    func deviceNameSaved() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        let field = try await openEditor(sdk)

        try await type("  Lobby iPad ", into: field, sdk)
        try await sdk.widgetsTap(exactly: "Save") { self.liveTest.deviceName == "Lobby iPad" }
        #expect(WidgetsDebugState.storedString("live_test.device_name") == "Lobby iPad")
        try await sdk.waitUntil("the name on the details screen") { sdk.widgetsIsShowing(exactly: "Device name, Lobby iPad") }
    }

    // Fails if: DigiaDebugSettingsView.swift `DeviceNameEditor.init` stops seeding the field with
    // `liveTest.deviceName`, or Cancel starts saving.
    @Test("the editor starts from the name already set, and Cancel leaves it alone")
    func deviceNameCancel() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        liveTest.setDeviceName("Kiosk 4")
        let field = try await openEditor(sdk)
        #expect(field.text == "Kiosk 4")

        try await type("Something else", into: field, sdk)
        try await sdk.widgetsTap(exactly: "Cancel") { !sdk.widgetsIsShowing(exactly: "Shown in the dashboard device list.") }
        #expect(liveTest.deviceName == "Kiosk 4")
    }

    // Fails if: LiveTestService.swift `setDeviceName` stores a blank name instead of removing it.
    @Test("saving a blank name clears it, and the device model is used again")
    func deviceNameCleared() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        liveTest.setDeviceName("Kiosk 4")
        let field = try await openEditor(sdk)

        try await type("   ", into: field, sdk)
        try await sdk.widgetsTap(exactly: "Save") { self.liveTest.deviceName == nil }
        #expect(WidgetsDebugState.storedString("live_test.device_name") == nil)
        try await sdk.waitUntil("the fallback text") { sdk.widgetsIsShowing(exactly: "Device name, Not set — using the device model") }
    }

    // Fails if: DigiaDebugSettingsView.swift's Save does anything but set the field's own text.
    @Test("saving without editing keeps the name")
    func deviceNameKept() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        liveTest.setDeviceName("Kiosk 4")
        _ = try await openEditor(sdk)

        try await sdk.widgetsTap(exactly: "Save") { !sdk.widgetsIsShowing(exactly: "Shown in the dashboard device list.") }
        #expect(liveTest.deviceName == "Kiosk 4")
    }

    /// The device-name row is a `Button` with `.buttonStyle(.plain)` whose label is a VStack, a
    /// `Spacer` and the pencil: a plain button is hit only where it draws, so with a short name the
    /// middle of the row (the spacer) takes no touch. Flutter's `ListTile` opens the editor from
    /// anywhere on the row.
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

    /// iOS only: the editor caps a name at 80 characters as it is typed (Flutter's field caps it
    /// with `maxLength`).
    // Fails if: DigiaDebugSettingsView.swift `DeviceNameEditor` drops its
    // `if value.count > 80 { deviceName = String(value.prefix(80)) }`.
    @Test("a name longer than 80 characters is cut to 80")
    func deviceNameCapped() async throws {
        let sdk = try await boot()
        defer { sdk.widgetsFinish() }
        let field = try await openEditor(sdk)

        try await type(String(repeating: "x", count: 100), into: field, sdk)
        try await sdk.widgetsTap(exactly: "Save") { self.liveTest.deviceName != nil }
        #expect(liveTest.deviceName == String(repeating: "x", count: 80))
    }
}
}
