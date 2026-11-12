import SwiftUI

/// The game surfaces. Each reuses the nudge container behavior for its style:
/// the dialog draws the centered card, the sheet rides `DigiaBottomSheet`
/// with the locked game chrome (no handle, no drag, no backdrop dismiss), and
/// full screen fills the window. Every surface always draws the native close
/// button — including while loading — and shows a native loader until `ready`.
/// Backdrop taps do nothing on all three.
@MainActor
struct GameContainerView: View {
    @ObservedObject var game: GamePresentation
    var viewportSize: CGSize? = nil
    var safeAreaInsets: UIEdgeInsets = .zero

    var body: some View {
        switch game.request.container {
        case .dialog:
            dialogBody
        case .bottomSheet:
            sheetBody
        case .fullScreen:
            fullScreenBody
        }
    }

    // MARK: - Dialog

    private var dialogBody: some View {
        let viewport = viewportSize ?? UIScreen.main.bounds.size
        let width = max(1, viewport.width * 0.86)
        let height = min(max(1, game.request.height), max(1, viewport.height))
        return ZStack {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                // Absorbs taps so they neither dismiss nor pass through.
                .onTapGesture {}
            VStack(spacing: 0) {
                GameWebViewHost(game: game)
                    .frame(width: width, height: height)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .overlay(alignment: .topTrailing) {
                NudgeCloseButton(
                    config: .defaults,
                    action: { GamePresenter.dismiss() }
                )
            }
            .overlay { if !game.isReady { loaderDots } }
        }
        .frame(width: viewport.width, height: viewport.height)
    }

    // MARK: - Bottom sheet

    private var sheetBody: some View {
        DigiaBottomSheet(
            config: .game,
            scrollable: false,
            onDismiss: {},
            content: {
                GameWebViewHost(game: game)
                    .frame(height: max(1, game.request.height))
            },
            cardOverlay: AnyView(NudgeCloseButton(
                config: .defaults,
                action: { GamePresenter.dismiss() }
            ))
        )
        .overlay { if !game.isReady { loaderDots } }
    }

    // MARK: - Full screen

    private var fullScreenBody: some View {
        GeometryReader { geometry in
            ZStack {
                GameWebViewHost(game: game)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                if !game.isReady {
                    loaderDots
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

    private var loaderDots: some View {
        ZStack {
            Color(.systemBackground)
            ProgressView()
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }
}
