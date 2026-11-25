import Foundation

/// Who shows a game: the app's root cover (the default) or the open rewards
/// page. A page claims the layer when it opens and releases it when it goes;
/// the token keeps a stale page from clearing a newer page's claim. A game
/// already open at claim time stays on the root cover. A claim whose page is
/// no longer on screen counts for nothing and is dropped, so a page that went
/// away without releasing can never hide a game from the root cover (the
/// overlay would then block touches for a game nobody shows).
@MainActor
enum GameLayerOwner {
    enum Layer: Equatable { case root, rewards }

    private static var claimed: (token: Int, existingGame: ObjectIdentifier?, isLive: () -> Bool)?
    private static var lastToken = 0

    static func claim(existingGame: ObjectIdentifier?, isLive: @escaping () -> Bool = { true }) -> Int {
        lastToken += 1
        claimed = (lastToken, existingGame, isLive)
        return lastToken
    }

    /// Releases only the claim `token` made.
    static func release(_ token: Int) {
        guard claimed?.token == token else { return }
        claimed = nil
    }

    static func layer(for game: ObjectIdentifier) -> Layer {
        guard let current = claimed else { return .root }
        guard current.isLive() else {
            claimed = nil
            return .root
        }
        return current.existingGame == game ? .root : .rewards
    }

    static func resetForTesting() {
        claimed = nil
    }
}
