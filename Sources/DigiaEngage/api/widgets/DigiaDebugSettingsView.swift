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
    @State private var showRestartHint = false
    @State private var showSession = false

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
                        title: "Digia bubble",
                        isOn: Binding(
                            get: { overlay.isVisible },
                            set: { overlay.setVisible($0) }
                        )
                    )
                }
            }
            .navigationTitle("Digia Debug Settings")
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
