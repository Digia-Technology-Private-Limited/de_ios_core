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
    @ObservedObject private var instance = SDKInstance.shared
    @State private var showRestartHint = false
    @State private var showSession = false
    @State private var showCapture = false

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
                    SettingsToggleRow(
                        title: "Anchorless Capture",
                        subtitle: "Capture one screen at a time for Spotlight authoring.",
                        onTap: { showCapture = true },
                        isOn: Binding(
                            get: { instance.captureModeEnabled },
                            set: { instance.setCaptureModeEnabled($0) }
                        )
                    )
                    .background(
                        NavigationLink(
                            destination: DigiaCaptureSessionScreen(),
                            isActive: $showCapture
                        ) { EmptyView() }
                        .hidden()
                    )
                    HStack {
                        Text("Live test")
                        Spacer()
                        Text(liveTest.connectionState.label)
                            .foregroundColor(.secondary)
                    }
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

@MainActor
private struct DigiaCaptureSessionScreen: View {
    @ObservedObject private var instance = SDKInstance.shared

    var body: some View {
        List {
            SettingsToggleRow(
                title: "Capture current screen",
                        subtitle: "Turn this on, then tap the camera icon on the Digia bubble.",
                isOn: Binding(
                    get: { instance.captureModeEnabled },
                    set: { instance.setCaptureModeEnabled($0) }
                )
            )
            if instance.capturedPages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No screens captured yet.")
                        .font(.headline)
                    Text("Open the screen you want to author, then tap the capture button on the floating bubble.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
            } else {
                Section("Captured screens") {
                    ForEach(instance.capturedPages) { page in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(page.pageKey)
                            Text("capture \(page.assetId) · \(page.capturedAt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Anchorless Capture")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension LiveTestConnectionState {
    var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .error: return "Reconnecting…"
        }
    }
}
