import SwiftUI

/// Debug-only settings screen. Reachable via `Digia.presentDebugSettings(from:)`
/// or a deeplink — both gate on `DigiaDebugDetection`, so this never surfaces
/// in production.
///
/// Hosts live testing, capture or sync, and the Digia bubble controls.
@MainActor
public struct DigiaDebugSettingsView: View {
    @ObservedObject private var instance = SDKInstance.shared
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()
    @ObservedObject private var overlay = SDKInstance.shared.debugOverlayControllerSnapshot()
    @ObservedObject private var liveTest = SDKInstance.shared.liveTestServiceSnapshot()
    @State private var showRestartHint = false
    @State private var showSession = false
    @State private var showLiveTesting = false

    public init() {}

    public var body: some View {
        // Defense in depth: presentDebugSettings(from:) already gates this, but
        // this is a public struct a host could construct directly, bypassing it.
        if DigiaDebugDetection.isDebugBuild() {
            content
        }
    }

    private var content: some View {
        NavigationView {
            List {
                Section {
                    SettingsToggleRow(
                        title: "Live testing",
                        subtitle: liveTest.connectionState.label(
                            enabled: liveTest.isEnabled,
                            deviceName: liveTest.deviceName
                        ),
                        onTap: { showLiveTesting = true },
                        isOn: Binding(
                            get: { liveTest.isEnabled },
                            set: { liveTest.setEnabled($0) }
                        )
                    )
                    .background(
                        NavigationLink(
                            destination: LiveTestingDetailsScreen(liveTest: liveTest),
                            isActive: $showLiveTesting
                        ) { EmptyView() }
                        .hidden()
                    )
                    Group {
                        if instance.isCaptureSupported {
                            SettingsToggleRow(
                                title: "Page & component capture",
                                subtitle: "Discover components and capture pages for authoring.",
                                onTap: { showSession = true },
                                isOn: Binding(
                                    get: { instance.captureModeEnabled },
                                    set: { instance.setCaptureModeEnabled($0) }
                                )
                            )
                        } else {
                            SettingsToggleRow(
                                title: "Sync",
                                subtitle: "Syncs the SDK with the Dashboard.",
                                onTap: { showSession = true },
                                isOn: Binding(
                                    get: { registry.isEnabled },
                                    set: { onToggleSync($0) }
                                )
                            )
                        }
                    }
                    .background(
                        NavigationLink(
                            destination: DigiaRecordedSessionScreen(),
                            isActive: $showSession
                        ) { EmptyView() }
                        .hidden()
                    )
                    SettingsToggleRow(
                        title: "Digia bubble",
                        isOn: Binding(
                            get: { overlay.isVisible },
                            set: { overlay.setVisible($0) }
                        )
                    )
                }
            }
            .navigationTitle("Digia Debug Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
        .alert("Restart recommended", isPresented: $showRestartHint) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                "Restart the app to record screens, anchors, and slots that already "
                    + "loaded before recording was turned on."
            )
        }
    }

    private func onToggleSync(_ value: Bool) {
        let wasEnabled = registry.isEnabled
        registry.setEnabled(value)
        // Dedupe means anything already on screen won't retroactively record
        // without a reload.
        if value && !wasEnabled {
            showRestartHint = true
        }
    }
}

extension LiveTestConnectionState {
    func label(enabled: Bool, deviceName: String?) -> String {
        guard enabled else { return "Off" }
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected:
            return deviceName.map { "Connected as \($0)" }
                ?? "Connected — visible on the dashboard"
        case .error: return "Connection error — retrying…"
        }
    }
}

@MainActor
private struct LiveTestingDetailsScreen: View {
    @ObservedObject var liveTest: LiveTestService
    @State private var showDeviceNameEditor = false

    var body: some View {
        List {
            SettingsToggleRow(
                title: "Live testing",
                subtitle: liveTest.connectionState.label(
                    enabled: liveTest.isEnabled,
                    deviceName: liveTest.deviceName
                ),
                isOn: Binding(
                    get: { liveTest.isEnabled },
                    set: { liveTest.setEnabled($0) }
                )
            )
            Button {
                showDeviceNameEditor = true
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Device name")
                        Text(liveTest.deviceName ?? "Not set — using the device model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "pencil")
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Device ID")
                Text(liveTest.deviceId ?? "")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Live testing")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showDeviceNameEditor) {
            DeviceNameEditor(liveTest: liveTest)
        }
    }
}

@MainActor
private struct DeviceNameEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var liveTest: LiveTestService
    @State private var deviceName: String

    init(liveTest: LiveTestService) {
        self.liveTest = liveTest
        _deviceName = State(initialValue: liveTest.deviceName ?? "")
    }

    var body: some View {
        NavigationView {
            Form {
                TextField("My test device", text: $deviceName)
                    .onChange(of: deviceName) { value in
                        if value.count > 80 {
                            deviceName = String(value.prefix(80))
                        }
                    }
                Text("Shown in the dashboard device list.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .navigationTitle("Device name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        liveTest.setDeviceName(deviceName)
                        dismiss()
                    }
                }
            }
        }
    }
}
