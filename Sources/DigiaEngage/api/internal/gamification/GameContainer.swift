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
struct GameContainer: View {
    @ObservedObject var game: GamePresentation
    var safeAreaInsets: UIEdgeInsets = .zero

    @State private var revealed = false

    private var visible: Bool { revealed && !game.isClosing }

    var body: some View {
        GeometryReader { geometry in
            // The controls overlay the full-size web view, so their padding
            // can never grow the layout. They used to sit in a ZStack with
            // the padding outside a full-size frame: the ZStack grew by the
            // padding and the outer frame re-centred it, shifting the
            // controls by half the inset — and the 6pt hit-box margin around
            // each circle was never subtracted.
            GameWebViewHost(game: game)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: GameChrome.gap - 2 * GameChrome.hitInset) {
                        if game.request.showMute {
                            GameMuteButton(muted: game.isMuted) { game.toggleMute() }
                        }
                        // The X is opt-out: back and the skin's `close` still
                        // close a game whose X is hidden.
                        if game.request.showClose {
                            GameCloseButton { GamePresenter.dismiss() }
                        }
                    }
                    .padding(.top, safeAreaInsets.top + GameChrome.top - GameChrome.hitInset)
                    .padding(.trailing, safeAreaInsets.right + GameChrome.trailing - GameChrome.hitInset)
                }
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

/// The fixed close/mute geometry, not configurable: each control is a
/// `circle` inside a `hitBox`, the close circle sits `top` below the top safe
/// inset and `trailing` in from the right one, and the mute circle sits `gap`
/// to its left.
enum GameChrome {
    static let circle: CGFloat = 36
    static let hitBox: CGFloat = 48
    static let top: CGFloat = 8
    static let trailing: CGFloat = 12
    static let gap: CGFloat = 8
    /// The hit box's margin around the circle on each side.
    static let hitInset: CGFloat = (hitBox - circle) / 2
}

/// The native sound toggle, left of the close button; same geometry.
private struct GameMuteButton: View {
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6)).frame(width: GameChrome.circle, height: GameChrome.circle)
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: GameChrome.hitBox, height: GameChrome.hitBox)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(muted ? "Unmute" : "Mute")
    }
}

/// The native close control: a 36pt translucent-black circle with an 18pt white
/// X inside a 48pt hit box. Same geometry as the Android game close button.
private struct GameCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.black.opacity(0.6)).frame(width: GameChrome.circle, height: GameChrome.circle)
                CanvasCloseIcon(size: 18).foregroundColor(.white)
            }
            .frame(width: GameChrome.hitBox, height: GameChrome.hitBox)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}
