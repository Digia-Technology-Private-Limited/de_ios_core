import SwiftUI

/// The game surface: always full screen and transparent. It is presented only
/// after the skin sends `ready` (see `GamePresentation.preload()`), so there is
/// no loading state: the skin and the native close button fade in together.
/// Taps never pass through to the host app while the game is on screen.
@MainActor
struct GameContainerView: View {
    @ObservedObject var game: GamePresentation
    var safeAreaInsets: UIEdgeInsets = .zero

    @State private var revealed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GameWebViewHost(game: game)
                    .frame(width: geometry.size.width, height: geometry.size.height)
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
            .opacity(revealed ? 1 : 0)
            .onAppear {
                withAnimation(.easeOut(duration: 0.18)) { revealed = true }
            }
        }
        .ignoresSafeArea()
    }
}
