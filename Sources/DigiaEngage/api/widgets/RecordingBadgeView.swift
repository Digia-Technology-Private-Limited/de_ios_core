import SwiftUI

/// Floating "Digia" debug bubble. Tap presents debug settings; drag repositions
/// and snaps to the nearer edge on release.
///
/// Shown when `DigiaDebugOverlayController.isVisible` is true — its own
/// persisted setting, flipped on automatically when recording mode turns on.
/// The pulsing red dot reflects recording being active, independent of bubble
/// visibility.
///
/// Also re-checks `DigiaDebugDetection.isDebugBuild()` — defense in depth.
@MainActor
struct RecordingBadgeView: View {
    @ObservedObject private var overlay = SDKInstance.shared.debugOverlayControllerSnapshot()

    var body: some View {
        if overlay.isVisible && DigiaDebugDetection.isDebugBuild() {
            DraggableBadge()
        }
    }
}

@MainActor
private struct DraggableBadge: View {
    private static let margin: CGFloat = 8
    // Cleared well below a typical nav bar, not just the status bar — a
    // host's headerShown nav bar would otherwise sit right in that gap.
    private static let defaultTopClearance: CGFloat = 100

    @State private var offset: CGSize?
    @State private var dragStartOffset: CGSize?
    @State private var badgeSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let current = offset ?? CGSize(width: Self.margin, height: proxy.safeAreaInsets.top + Self.defaultTopClearance)

            BadgeContent()
                .background(
                    GeometryReader { inner -> Color in
                        // .global matches the coordinate space a host's hitTest(_:with:)
                        // uses — a manually-computed local-space rect didn't line up
                        // with real touches.
                        let globalFrame = inner.frame(in: .global)
                        DispatchQueue.main.async {
                            badgeSize = inner.size
                            SDKInstance.shared.debugOverlayControllerSnapshot().badgeFrame = globalFrame
                        }
                        return Color.clear
                    }
                )
                .offset(x: current.width, y: current.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStartOffset ?? current
                            dragStartOffset = start
                            let maxX = max(0, proxy.size.width - badgeSize.width)
                            let minY = proxy.safeAreaInsets.top
                            let maxY = max(minY, proxy.size.height - proxy.safeAreaInsets.bottom - badgeSize.height)
                            offset = CGSize(
                                width: min(max(0, start.width + value.translation.width), maxX),
                                height: min(max(minY, start.height + value.translation.height), maxY)
                            )
                        }
                        .onEnded { _ in
                            dragStartOffset = nil
                            let latest = offset ?? current
                            let center = proxy.size.width / 2
                            let snappedX: CGFloat = (latest.width + badgeSize.width / 2) < center
                                ? Self.margin
                                : proxy.size.width - badgeSize.width - Self.margin
                            withAnimation(.easeOut(duration: 0.22)) {
                                offset = CGSize(width: snappedX, height: latest.height)
                            }
                        }
                )
                .onTapGesture {
                    presentDebugSettings()
                }
                .onDisappear {
                    SDKInstance.shared.debugOverlayControllerSnapshot().badgeFrame = nil
                }
        }
    }

    private func presentDebugSettings() {
        guard let presenter = ViewControllerUtil.topViewController() else { return }
        Digia.presentDebugSettings(from: presenter)
    }
}

@MainActor
private struct BadgeContent: View {
    @ObservedObject private var registry = SDKInstance.shared.componentRegistrySnapshot()
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            if registry.isEnabled {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(pulse ? 1 : 0.35)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            pulse = true
                        }
                    }
            }
            Text("Digia")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.87))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
