import SwiftUI
import Foundation

/// Small always-on-top floating "Digia" bubble shown by `DigiaHost` — a general
/// debug-tools launcher, not specific to any one feature. Tapping it presents the debug
/// settings screen; dragging it repositions it, snapping to whichever horizontal edge
/// it's closer to on release (vertical position is unconstrained).
///
/// Shown whenever `DigiaDebugOverlayController.isVisible` is true — its own independent,
/// persisted setting. Turning on Engage Component Registry recording mode flips that to
/// true automatically (see `ComponentRegistryService.setEnabled`), but the bubble can
/// also be shown on its own for future debug controls unrelated to recording. The
/// pulsing red dot inside it specifically reflects recording being active — the bubble
/// itself can be visible with no dot if recording is off.
///
/// Gated on `DigiaDebugDetection.isDebugBuild()` in addition to the overlay controller's
/// own visible flag — same defense-in-depth reasoning as elsewhere in this feature.
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

    @State private var offset: CGSize?
    @State private var dragStartOffset: CGSize?
    @State private var badgeSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let current = offset ?? CGSize(width: Self.margin, height: proxy.safeAreaInsets.top + Self.margin)
            let frame = CGRect(x: current.width, y: current.height, width: badgeSize.width, height: badgeSize.height)

            BadgeContent()
                .background(
                    GeometryReader { inner -> Color in
                        DispatchQueue.main.async { badgeSize = inner.size }
                        return Color.clear
                    }
                )
                .offset(x: current.width, y: current.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            NSLog("%@", "[DigiaBadgeDebug] DragGesture.onChanged fired, translation=\(value.translation)")
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
                    NSLog("%@", "[DigiaBadgeDebug] onTapGesture fired")
                    presentDebugSettings()
                }
                // Keeps DigiaDebugOverlayController.badgeFrame in sync so a host's hit
                // testing (DigiaRootOverlayView in rn/core) can tell "this touch landed
                // on the bubble" apart from "this touch landed on empty SwiftUI space" —
                // see the doc comment on badgeFrame for why that distinction needs help.
                .onChange(of: frame) { newValue in
                    NSLog("%@", "[DigiaBadgeDebug] badgeFrame changed to \(newValue)")
                    SDKInstance.shared.debugOverlayControllerSnapshot().badgeFrame = newValue
                }
                .onAppear {
                    NSLog("%@", "[DigiaBadgeDebug] onAppear, publishing badgeFrame=\(frame)")
                    SDKInstance.shared.debugOverlayControllerSnapshot().badgeFrame = frame
                }
                .onDisappear {
                    NSLog("%@", "[DigiaBadgeDebug] onDisappear, clearing badgeFrame")
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
