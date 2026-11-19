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

/// Decides internal, external or refused. A link whose scheme is one of the
/// app's own URL schemes, or an http(s) link on one of `appLinkHosts`, is
/// internal. Everything else (tel:, mailto:, other apps, other sites) is external.
enum RewardsLinkRouter {
    private static let refusedSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "intent",
    ]

    /// The schemes this app registers in `CFBundleURLTypes`, lowercased.
    static var appURLSchemes: Set<String> {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return Set(types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }.map { $0.lowercased() })
    }

    static func route(
        _ raw: String, appSchemes: Set<String> = appURLSchemes, appLinkHosts: Set<String> = []
    ) -> RewardsLinkRoute {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              !refusedSchemes.contains(scheme)
        else { return .refused }
        guard scheme == "http" || scheme == "https" else {
            return appSchemes.contains(scheme) ? .internal(url) : .external(url)
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return .refused }
        return appLinkHosts.contains(host) ? .internal(url) : .external(url)
    }
}
