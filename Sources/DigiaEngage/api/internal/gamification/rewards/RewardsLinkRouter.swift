import Foundation

/// Where a link the rewards page asked to open goes.
enum RewardsLinkRoute: Equatable {
    /// Dropped: a scheme that can run code or read files, or not a URL.
    case refused
    /// The rewards page closes, then the app handles the link.
    case `internal`(URL)
    /// Opens in an in-app browser over the page, which stays open.
    case external(URL)
}

/// Decides internal, external or refused. A custom (non-http) scheme or a link
/// on one of `appLinkHosts` is internal; any other http(s) link is external.
enum RewardsLinkRouter {
    private static let refusedSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "intent",
    ]

    static func route(_ raw: String, appLinkHosts: Set<String> = []) -> RewardsLinkRoute {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              !refusedSchemes.contains(scheme)
        else { return .refused }
        guard scheme == "http" || scheme == "https" else { return .internal(url) }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refused }
        return appLinkHosts.contains(host) ? .internal(url) : .external(url)
    }
}
