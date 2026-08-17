import SwiftUI

@MainActor
public struct DigiaDebugSettingsView: View {
    @ObservedObject private var overlay = SDKInstance.shared.debugOverlayControllerSnapshot()
    @ObservedObject private var liveTest = SDKInstance.shared.liveTestServiceSnapshot()
    @ObservedObject private var instance = SDKInstance.shared
    @State private var showLiveTesting = false
    @State private var showCapture = false

    public init() {}

    public var body: some View {
        if DigiaDebugDetection.isDebugBuild() {
            NavigationView {
                List {
                    Section {
                        SettingsToggleRow(
                            title: "Live testing",
                            subtitle: liveTest.statusLabel,
                            onTap: { showLiveTesting = true },
                            isOn: Binding(
                                get: { liveTest.isEnabled },
                                set: { liveTest.setEnabled($0) }
                            )
                        )
                        .background(
                            NavigationLink(
                                destination: LiveTestingDetailsScreen(),
                                isActive: $showLiveTesting
                            ) { EmptyView() }
                            .hidden()
                        )
                        if instance.isCaptureSupported {
                            SettingsToggleRow(
                                title: "Page & component capture",
                                subtitle: "Discover components and capture pages for authoring.",
                                onTap: { showCapture = true },
                                isOn: Binding(
                                    get: { instance.captureModeEnabled },
                                    set: { instance.setCaptureModeEnabled($0) }
                                )
                            )
                            .background(
                                NavigationLink(
                                    destination: DigiaRecordedSessionScreen(),
                                    isActive: $showCapture
                                ) { EmptyView() }
                                .hidden()
                            )
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
        }
    }
}

@MainActor
private struct LiveTestingDetailsScreen: View {
    @ObservedObject private var liveTest = SDKInstance.shared.liveTestServiceSnapshot()
    @State private var deviceName = ""

    var body: some View {
        List {
            SettingsToggleRow(
                title: "Live testing",
                subtitle: liveTest.statusLabel,
                isOn: Binding(
                    get: { liveTest.isEnabled },
                    set: { liveTest.setEnabled($0) }
                )
            )
            Section("Device name") {
                TextField("My test device", text: $deviceName)
                    .onChange(of: deviceName) { deviceName = String($0.prefix(80)) }
                    .onSubmit { liveTest.setDeviceName(deviceName) }
                Button("Save") { liveTest.setDeviceName(deviceName) }
            }
            Section("Device ID") {
                Text(liveTest.deviceId ?? "Unavailable")
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Live testing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { deviceName = liveTest.deviceName ?? "" }
    }
}

private extension LiveTestService {
    var statusLabel: String {
        guard isEnabled else { return "Off" }
        switch connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected:
            return deviceName.map { "Connected as \($0)" }
                ?? "Connected — visible on the dashboard"
        case .error: return "Connection error — retrying…"
        }
    }
}
