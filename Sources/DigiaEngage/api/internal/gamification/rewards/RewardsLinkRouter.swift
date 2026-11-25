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
/// other openable scheme goes to the app's deep-link handler. The openability
/// rule is `GameLinkPolicy.isOpenableLink`, so script-like schemes, `about`,
/// a link with no scheme and a web link with no host are refused — `about`
/// too, like on the game bridge. Pure logic.
enum RewardsLinkRouter {
    static func route(_ raw: String) -> RewardsLinkRoute {
        // Browsers drop tabs and newlines inside a scheme ("java\nscript:"); so do we:
        // strip ISO controls (U+0000–U+001F, U+007F), then trim, then parse.
        let stripped = String(raw.unicodeScalars.filter { !($0.value <= 0x1F || $0.value == 0x7F) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              GameLinkPolicy.isOpenableLink(url)
        else { return .refused }
        guard scheme == "http" || scheme == "https" else { return .internal(url) }
        return .external(url)
    }
}
