import SwiftUI

/// Debug-only settings screen for the Digia Engage SDK.
///
/// Reachable only via `Digia.presentDebugSettings(from:)` or `Digia.handleDeepLink`
/// — both gate on `SDKInstance.isDebugBuild` (see `DigiaDebugDetection`), so this
/// can never surface in a real production release.
///
/// Currently hosts the "recording mode" toggle for the Engage Component Registry
/// (auto-reports pages/anchors/slots seen at runtime so a PM can curate them on
/// the dashboard instead of typing keys by hand). Future debug-only testing
/// controls belong here too — kept as a simple list so adding another one is
/// just another row.
@MainActor
public struct DigiaDebugSettingsView: View {
    @State private var recordingEnabled: Bool

    public init() {
        _recordingEnabled = State(initialValue: SDKInstance.shared.componentRegistrySnapshot().isEnabled)
    }

    public var body: some View {
        NavigationView {
            List {
                Section {
                    Toggle("Recording mode", isOn: $recordingEnabled)
                        .onChange(of: recordingEnabled) { newValue in
                            SDKInstance.shared.componentRegistrySnapshot().setEnabled(newValue)
                        }
                } footer: {
                    Text(
                        "Reports pages, anchors, and slots seen in this app to the Engage "
                            + "dashboard as they render, for the PM to curate as usable/archived."
                    )
                }
            }
            .navigationTitle("Digia Debug Settings")
        }
    }
}
