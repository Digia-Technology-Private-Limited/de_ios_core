import SwiftUI

/// The game surface: always full screen and transparent. The web view is
/// non-opaque, so once the skin is `ready` only the skin and the native close
/// button are visible over the host app. Until then a dim scrim, a small
/// spinner and "Loading game…" cover the window. The native close button is
/// pinned top-right inside the safe area at all times — including while
/// loading. Taps never pass through to the host app.
@MainActor
struct GameContainerView: View {
    @ObservedObject var game: GamePresentation
    var safeAreaInsets: UIEdgeInsets = .zero

    /// rgba(10, 12, 40, 0.85)
    private static let scrim = Color(red: 10 / 255, green: 12 / 255, blue: 40 / 255).opacity(0.85)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GameWebViewHost(game: game)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if !game.isReady {
                    loader
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                NudgeCloseButton(
                    config: .defaults,
                    action: { GamePresenter.dismiss() }
                )
                .frame(
                    width: geometry.size.width, height: geometry.size.height,
                    alignment: .topTrailing
                )
                .padding(.top, safeAreaInsets.top + 12)
                .padding(.trailing, 12)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture {}
        }
        .ignoresSafeArea()
    }

    private var loader: some View {
        ZStack {
            Self.scrim
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.9)
                Text("Loading game…")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
