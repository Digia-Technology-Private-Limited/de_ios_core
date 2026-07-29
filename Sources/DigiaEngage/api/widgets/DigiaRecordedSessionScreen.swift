import SwiftUI

/// Lists every distinct page/anchor/slot key recorded this process — pushed
/// from `DigiaDebugSettingsView`'s "Sync" row. In-memory only, cleared on a
/// fresh process.
@MainActor
struct DigiaRecordedSessionScreen: View {
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()

    var body: some View {
        List {
            Section {
                SettingsToggleRow(
                    title: "Sync",
                    isOn: Binding(
                        get: { registry.isEnabled },
                        set: { registry.setEnabled($0) }
                    )
                )
            }
            Section {
                if registry.recordedThisSession.isEmpty {
                    Text("Nothing synced yet this session.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(registry.recordedThisSession) { entry in
                        HStack {
                            TypeTag(type: entry.type)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.key)
                                if let screenName = entry.screenName {
                                    Text("screen: \(screenName)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(
                    registry.recordedThisSession.isEmpty
                        ? "Synced Keys"
                        : "Synced Keys (\(registry.recordedThisSession.count))"
                )
            }
        }
        .navigationTitle("Synced This Session")
        // This screen is a drill-down from L1's "Sync" row, not a root screen —
        // per HIG (and Apple's own Settings app), a pushed detail screen uses
        // the compact inline title, not the large title reserved for roots.
        // Without this, the large title's loose flow left it visually
        // crowding the Sync toggle row directly beneath it.
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct TypeTag: View {
    let type: String

    var body: some View {
        Text(type)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.15))
            .foregroundColor(.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
