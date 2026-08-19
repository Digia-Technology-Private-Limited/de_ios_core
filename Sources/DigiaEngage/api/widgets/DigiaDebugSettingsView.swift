import SwiftUI

/// Debug-only settings screen. Reachable via `Digia.presentDebugSettings(from:)`
/// or a deeplink — both gate on `DigiaDebugDetection`, so this never surfaces
/// in production.
///
/// Hosts the Engage Component Registry's "Sync" toggle and the "Digia bubble"
/// visibility toggle; more debug controls can be added as rows here.
@MainActor
public struct DigiaDebugSettingsView: View {
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()
    @ObservedObject private var overlay = SDKInstance.shared.debugOverlayControllerSnapshot()
    @ObservedObject private var liveTest = SDKInstance.shared.liveTestServiceSnapshot()
    @State private var showRestartHint = false
    @State private var showSession = false
    @State private var showDeviceNameEditor = false

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
                        title: "Sync",
                        subtitle: "Syncs the SDK with the Dashboard.",
                        onTap: { showSession = true },
                        isOn: Binding(
                            get: { registry.isEnabled },
                            set: { onToggleSync($0) }
                        )
                    )
                    .background(
                        // .background(), not a sibling row: even a hidden row still
                        // gets List's row background/padding, showing as a stray box.
                        NavigationLink(
                            destination: DigiaRecordedSessionScreen(),
                            isActive: $showSession
                        ) { EmptyView() }
                        .hidden()
                    )
                    HStack {
                        Text("Live test")
                        Spacer()
                        Text(liveTest.connectionState.label(deviceName: liveTest.deviceName))
                            .foregroundColor(.secondary)
                    }
                    Button {
                        showDeviceNameEditor = true
                    } label: {
                        HStack {
                            Text("Device name")
                            Spacer()
                            Text(liveTest.deviceName ?? "Not set")
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
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
        .sheet(isPresented: $showDeviceNameEditor) {
            DeviceNameEditor(liveTest: liveTest)
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
    func label(deviceName: String?) -> String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return deviceName.map { "Connected as \($0)" } ?? "Connected"
        case .error: return "Reconnecting…"
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
