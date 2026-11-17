import SwiftUI

/// Shared motion numbers; identical to Android (`GAME_OPEN_MS`, `GAME_EXIT_MS`,
/// `GAME_START_SCALE`). Reduced motion removes the animation and the scale.
enum GameMotion {
    static let openDuration: Double = 0.24
    static let exitDuration: Double = 0.18
    static let startScale: CGFloat = 0.94

    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
}

/// The game surface: always full screen and transparent. It is presented only
/// after the skin sends `ready` (see `GamePresentation.preload()`), so there
/// is no loading state: the skin and the native close button animate in
/// together (fade + scale 0.94→1, 240ms ease-out) and out on close (180ms
/// ease-in) before the cover is removed. Taps never pass through to the host
/// app while the game is on screen.
///
/// The rendered size is reported back as the `viewport` push whenever it
/// changes (rotation, split screen); the safe area comes from the window.
@MainActor
struct GameContainerView: View {
    @ObservedObject var game: GamePresentation
    var safeAreaInsets: UIEdgeInsets = .zero

    @State private var revealed = false

    private var visible: Bool { revealed && !game.isClosing }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GameWebViewHost(game: game)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                GameCloseButton { GamePresenter.dismiss() }
                    .frame(
                        width: geometry.size.width, height: geometry.size.height,
                        alignment: .topTrailing
                    )
                    .padding(.top, safeAreaInsets.top + 8)
                    .padding(.trailing, safeAreaInsets.right + 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture {}
            .opacity(visible ? 1 : 0)
            .scaleEffect(visible || GameMotion.reduced ? 1 : GameMotion.startScale)
            .animation(
                GameMotion.reduced
                    ? nil
                    : (game.isClosing
                        ? .easeIn(duration: GameMotion.exitDuration)
                        : .easeOut(duration: GameMotion.openDuration)),
                value: visible
            )
            .onAppear {
                revealed = true
                game.pushViewportIfChanged(
                    size: geometry.size,
                    safeArea: GameSafeArea.fullScreen(system: safeAreaInsets))
            }
            .onChange(of: geometry.size) { size in
                game.pushViewportIfChanged(
                    size: size,
                    safeArea: GameSafeArea.fullScreen(system: safeAreaInsets))
            }
            .onChange(of: safeAreaInsets) { insets in
                game.pushViewportIfChanged(
                    size: geometry.size,
                    safeArea: GameSafeArea.fullScreen(system: insets))
            }
        }
        .ignoresSafeArea()
    }
}

/// The native close control: a 36pt translucent-black circle with an 18pt white
/// X inside a 48pt hit box. Same geometry as the Android game close button.
private struct GameCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6)).frame(width: 36, height: 36)
                CanvasCloseIcon(size: 18).foregroundColor(.white)
            }
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
