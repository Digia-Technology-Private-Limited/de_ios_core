import Foundation
import SwiftUI

/// How a media item fills its box. Callers map campaign JSON to this; the wrappers (`MediaImage`,
/// `MediaLottie`, `MediaStill`) take it as a flat `fit` parameter and never parse campaigns.
enum MediaFit: String, Sendable, Equatable, Hashable {
    case cover
    case contain
    case fill

    /// The SwiftUI aspect for the fit. `nil` means stretch: the image is resizable with no
    /// aspect constraint (callers that size the wrapper themselves pass `.fill`).
    var contentMode: ContentMode? {
        switch self {
        case .cover: .fill
        case .contain: .fit
        case .fill: nil
        }
    }

    /// The `UIView` content mode for layers that need it (Lottie's animation view).
    var viewContentMode: UIView.ContentMode {
        switch self {
        case .cover: .scaleAspectFill
        case .contain: .scaleAspectFit
        case .fill: .scaleToFill
        }
    }
}

/// URLs a wrapper may fetch: non-blank, fully resolved (no `{{variable}}` template tokens left),
/// parseable and with a scheme. Anything else is an unusable URL: the wrapper draws its still
/// without fetching and reports `invalid_url`.
func mediaUsableURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("{{"),
        let url = URL(string: trimmed), url.scheme != nil
    else { return nil }
    return url
}
