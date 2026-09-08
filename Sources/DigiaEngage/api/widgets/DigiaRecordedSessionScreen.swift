import SwiftUI

@MainActor
struct DigiaRecordedSessionScreen: View {
    @ObservedObject private var instance = SDKInstance.shared
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()

    var body: some View {
        List {
            if instance.isCaptureSupported {
                SettingsToggleRow(
                    title: "Page & component capture",
                    isOn: Binding(
                        get: { instance.captureModeEnabled },
                        set: { instance.setCaptureModeEnabled($0) }
                    )
                )
                Section {
                    Text("Interactive elements and their required structure are always included.")
                        .foregroundColor(.secondary)
                    SettingsToggleRow(
                        title: "Include text nodes",
                        isOn: Binding(
                            get: { instance.captureTextEnabled },
                            set: { instance.setCaptureProfile(includeText: $0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "Include images and media",
                        isOn: Binding(
                            get: { instance.captureMediaEnabled },
                            set: { instance.setCaptureProfile(includeMedia: $0) }
                        )
                    )
                    SettingsToggleRow(
                        title: "Include other structural nodes",
                        isOn: Binding(
                            get: { instance.captureStructureEnabled },
                            set: { instance.setCaptureProfile(includeStructure: $0) }
                        )
                    )
                } header: {
                    Text("Capture profile")
                }
            } else {
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
                    Text(
                        instance.isCaptureSupported
                            ? "No pages, anchors, or slots detected yet."
                            : "Nothing synced yet this session."
                    )
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
                    instance.isCaptureSupported
                        ? "Detected this session"
                        : registry.recordedThisSession.isEmpty
                            ? "Synced Keys"
                            : "Synced Keys (\(registry.recordedThisSession.count))"
                )
            }
            if instance.isCaptureSupported {
                Section("Uploaded this session") {
                    if instance.capturedPages.isEmpty {
                        Text("No page captures uploaded yet.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(instance.capturedPages) { page in
                            HStack {
                                TypeTag(type: "page")
                                Text(page.pageKey)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(
            instance.isCaptureSupported ? "Page & component capture" : "Synced This Session"
        )
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
