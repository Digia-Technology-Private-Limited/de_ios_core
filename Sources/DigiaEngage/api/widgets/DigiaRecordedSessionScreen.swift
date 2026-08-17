import SwiftUI

@MainActor
struct DigiaRecordedSessionScreen: View {
    @ObservedObject private var instance = SDKInstance.shared
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()

    var body: some View {
        List {
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
            Section("Detected this session") {
                if registry.recordedThisSession.isEmpty {
                    Text("No pages, anchors, or slots detected yet.")
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
            }
            Section("Uploaded this session") {
                if instance.capturedPages.isEmpty {
                    Text("No page captures uploaded yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(instance.capturedPages) { page in
                        Label(page.pageKey, systemImage: "checkmark.circle")
                    }
                }
            }
        }
        .navigationTitle("Page & component capture")
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
