import SwiftUI

/// Debug-only settings screen for the Digia Engage SDK.
///
/// Reachable only via `Digia.presentDebugSettings(from:)` or `Digia.handleDeepLink`
/// — both gate on `SDKInstance.isDebugBuild` (see `DigiaDebugDetection`), so this
/// can never surface in a real production release.
///
/// Currently hosts the "Sync" toggle for the Engage Component Registry
/// (auto-reports pages/anchors/slots seen at runtime so a PM can curate them on the
/// dashboard instead of typing keys by hand) and the "Digia bubble" visibility
/// toggle. Future debug-only testing controls belong here too — kept as a simple
/// list so adding another one is just another row.
@MainActor
public struct DigiaDebugSettingsView: View {
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()
    @ObservedObject private var overlay = SDKInstance.shared.debugOverlayControllerSnapshot()
    @State private var showRestartHint = false
    @State private var showSession = false

    public init() {}

    public var body: some View {
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
                    SettingsToggleRow(
                        title: "Digia bubble",
                        isOn: Binding(
                            get: { overlay.isVisible },
                            set: { overlay.setVisible($0) }
                        )
                    )
                }
                NavigationLink(
                    destination: DigiaRecordedSessionScreen(),
                    isActive: $showSession
                ) { EmptyView() }
                .hidden()
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
        // Recording only fires the first time a page/anchor/slot loads (dedupe
        // set) — anything already on screen when this flips on won't
        // retroactively record without a reload.
        if value && !wasEnabled {
            showRestartHint = true
        }
    }
}
