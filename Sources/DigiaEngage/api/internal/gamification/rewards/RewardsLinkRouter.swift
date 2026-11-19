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
/// app's own URL schemes, or an http(s) link whose host matches `appLinkHosts`, is
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
        return matches(host: host, domains: appLinkHosts) ? .internal(url) : .external(url)
    }

    /// Whether `host` equals a domain entry, or, for a `*.example.com` entry,
    /// is `example.com` or any subdomain of it. Case-insensitive; malformed
    /// entries (scheme, path, port, spaces, empty labels) never match.
    static func matches(host: String, domains: Set<String>) -> Bool {
        let host = host.lowercased()
        for entry in domains {
            var domain = entry.trimmingCharacters(in: .whitespaces).lowercased()
            let wildcard = domain.hasPrefix("*.")
            if wildcard { domain.removeFirst(2) }
            guard isHostname(domain) else { continue }
            if host == domain || (wildcard && host.hasSuffix("." + domain)) { return true }
        }
        return false
    }

    private static func isHostname(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
