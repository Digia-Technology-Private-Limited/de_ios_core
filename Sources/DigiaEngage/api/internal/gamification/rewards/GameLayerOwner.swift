import Foundation

/// Who shows a game: the app's root cover (the default) or the open rewards
/// page. A page claims the layer when it opens and releases it when it goes;
/// the token keeps a stale page from clearing a newer page's claim. A game
/// already open at claim time stays on the root cover.
@MainActor
enum GameLayerOwner {
    enum Layer: Equatable { case root, rewards }

    private static var claimed: (token: Int, existingGame: ObjectIdentifier?)?
    private static var lastToken = 0

    static func claim(existingGame: ObjectIdentifier?) -> Int {
        lastToken += 1
        claimed = (lastToken, existingGame)
        return lastToken
    }

    /// Releases only the claim `token` made.
    static func release(_ token: Int) {
        guard claimed?.token == token else { return }
        claimed = nil
    }

    static func layer(for game: ObjectIdentifier) -> Layer {
        guard let claimed, claimed.existingGame != game else { return .root }
        return .rewards
    }

    static func resetForTesting() {
        claimed = nil
    }
}
