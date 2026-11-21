import Foundation

/// The rewards page address and what its web view may load.
enum RewardsPageURL {
    static let productionDefault = URL(string: "https://rewards.digia.tech")!
    static let sandboxDefault = URL(string: "https://rewards-dev.digia.tech")!

    /// The backend's `page.url` when it is a usable https address, else the
    /// default for the environment.
    static func resolve(pageUrl: String?, environment: DigiaEnvironment) -> URL {
        if let raw = pageUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: raw), url.scheme?.lowercased() == "https",
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil
        {
            return url
        }
        return environment == .sandbox ? sandboxDefault : productionDefault
    }

    /// Whether `url` has the same scheme, host and port as `pageURL`.
    static func isSameOrigin(_ url: URL?, as pageURL: URL?) -> Bool {
        guard let url, let pageURL,
              let origin = GameURLPolicy.normalizedOrigin(url)
        else { return false }
        return origin == GameURLPolicy.normalizedOrigin(pageURL)
    }

    /// Navigation inside the page's own origin loads; everything else is
    /// cancelled. `window.open` (no target frame) never opens.
    static func allowNavigation(url: URL, pageURL: URL?, hasTargetFrame: Bool) -> Bool {
        hasTargetFrame && isSameOrigin(url, as: pageURL)
    }

    /// A main-frame answer with an HTTP error status is a failed load.
    static func isHttpError(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode >= 400
    }
}
