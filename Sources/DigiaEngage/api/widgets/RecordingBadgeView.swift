import SwiftUI

/// Small always-on-top indicator shown by `DigiaHost` whenever Engage
/// Component Registry recording mode is on, so a developer walking the app
/// doesn't forget it's active. Tapping it presents the debug settings screen.
///
/// Gated on `DigiaDebugDetection.isDebugBuild()` in addition to the
/// registry's own `isEnabled` — same defense-in-depth reasoning as
/// `ComponentRegistryService` itself, in case a persisted `true` toggle
/// somehow survives into a non-debug install.
@MainActor
struct RecordingBadgeView: View {
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()

    var body: some View {
        if registry.isEnabled && DigiaDebugDetection.isDebugBuild() {
            VStack {
                HStack {
                    Button(action: presentDebugSettings) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 10, height: 10)
                            Text("Recording")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.87))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(8)
        }
    }

    private func presentDebugSettings() {
        guard let presenter = ViewControllerUtil.topViewController() else { return }
        Digia.presentDebugSettings(from: presenter)
    }
}
