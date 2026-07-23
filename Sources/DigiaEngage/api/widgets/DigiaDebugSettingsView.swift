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
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()
    @State private var showRestartHint = false

    public init() {}

    public var body: some View {
        NavigationView {
            List {
                Section {
                    // NavigationLink wraps only the title/subtitle text, not the
                    // Toggle — a sibling, not a descendant — so it keeps its own
                    // tap target and doesn't trigger navigation.
                    HStack {
                        NavigationLink(destination: DigiaRecordedSessionScreen()) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Recording mode")
                                Text(
                                    "Reports pages, anchors, and slots seen in this app to the "
                                        + "Engage dashboard as they render, for the PM to curate as "
                                        + "usable/archived. Tap to see everything recorded so far."
                                )
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { registry.isEnabled },
                            set: { onToggle($0) }
                        ))
                        .labelsHidden()
                    }
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

    private func onToggle(_ value: Bool) {
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
