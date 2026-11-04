import SwiftUI

/// The viewer's chrome (T10): close, and mute while a video is showing.
/// Same pixels as the buttons it replaces; mirrors Android `StoryChrome`.
@MainActor
struct StoryChrome: View {
    let closeButton: StoryOverlayButtonConfig
    let muteButton: StoryOverlayButtonConfig
    let showMute: Bool
    let muted: Bool
    let onClose: @MainActor () -> Void
    let onToggleMute: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if showMute, muteButton.visible {
                StoryChromeButton(
                    config: muteButton,
                    systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    accessibilityLabel: muted ? "Unmute story" : "Mute story",
                    action: onToggleMute
                )
            }
            if closeButton.visible {
                StoryChromeButton(
                    config: closeButton,
                    systemImage: "xmark",
                    accessibilityLabel: "Close story",
                    action: onClose
                )
            }
        }
    }
}

@MainActor
private struct StoryChromeButton: View {
    let config: StoryOverlayButtonConfig
    let systemImage: String
    let accessibilityLabel: String
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: { action() }) {
            Image(systemName: systemImage)
                .font(.system(size: CGFloat(config.size) * 0.5, weight: .regular))
                .foregroundStyle(Color(hex: config.iconColor) ?? .white)
                .frame(width: CGFloat(config.size), height: CGFloat(config.size))
                .background(Color(hex: config.backgroundColor) ?? .black)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .frame(width: max(CGFloat(config.size), 48), height: max(CGFloat(config.size), 48))
        .accessibilityLabel(accessibilityLabel)
    }
}
