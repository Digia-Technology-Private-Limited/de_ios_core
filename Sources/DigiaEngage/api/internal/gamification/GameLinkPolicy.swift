import Foundation

/// The one link-safety rule for every surface that opens an authored URL: the
/// game bridge (`action` openLink/openUrl/deeplink) and the rewards page.
/// Schemes that would run code, read local data or bypass the host's link
/// routing are never opened; web links need a host; any other scheme is an
/// app deep link the host handles. Pure logic, so unit tests drive it
/// directly. Mirrors Android's `GameLinkPolicy`.
///
/// `about` is blocked on both surfaces: `about:blank` inside a web view is a
/// blank page, never a destination the host can route.
enum GameLinkPolicy {
    /// Schemes the SDK never opens, whatever the surface sends.
    static let blockedLinkSchemes: Set<String> = [
        "javascript", "vbscript", "data", "blob", "file", "content", "about", "intent",
    ]

    /// Whether `url` may be handed to the host's link routing. Web links
    /// need a host; app deep links (`medihub://cart`) only a safe scheme.
    /// Never throws.
    static func isOpenableLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        if scheme == "http" || scheme == "https" { return !(url.host ?? "").isEmpty }
        return !blockedLinkSchemes.contains(scheme)
    }

    /// Whether `raw` may be handed to the host's link routing. Strips control
    /// characters first, so a scheme break (`java\nscript:`) cannot smuggle a
    /// blocked scheme past the check. Never throws.
    static func isOpenableLink(_ raw: String) -> Bool {
        openableURL(raw) != nil
    }

    /// The validated URL for `raw`, or nil. The one policy entry point that
    /// strips control characters before parsing, so the bridge and every
    /// surface decide on the same canonical string they then open. Never throws.
    static func openableURL(_ raw: String) -> URL? {
        let stripped = String(raw.unicodeScalars.filter { !($0.value <= 0x1F || $0.value == 0x7F) })
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), isOpenableLink(url) else { return nil }
        return url
    }
}
