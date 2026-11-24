import Foundation

/// Where a link the rewards page asked to open goes.
enum RewardsLinkRoute: Equatable {
    /// Dropped: a scheme that can run code or read files, or not a URL.
    case refused
    /// The rewards page closes, then the app handles the link.
    case `internal`(URL)
    /// Opens outside the app through the system; the page stays open.
    case external(URL)
}

/// Decides internal, external or refused, by scheme. An http(s) link is external,
/// so the system can hand the app's own universal links back to the app. Any
/// other allowed scheme goes to the app's deep-link handler.
enum RewardsLinkRouter {
    private static let refusedSchemes: Set<String> = [
        "javascript", "data", "file", "blob", "vbscript", "intent", "content",
    ]

    static func route(_ raw: String) -> RewardsLinkRoute {
        // Browsers drop tabs and newlines inside a scheme ("java\nscript:"); so do we:
        // strip ISO controls (U+0000–U+001F, U+007F), then trim, then parse.
        let stripped = String(raw.unicodeScalars.filter { !($0.value <= 0x1F || $0.value == 0x7F) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              !refusedSchemes.contains(scheme)
        else { return .refused }
        guard scheme == "http" || scheme == "https" else { return .internal(url) }
        guard let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedHost, !host.isEmpty
        else { return .refused }
        return .external(url)
    }
}
