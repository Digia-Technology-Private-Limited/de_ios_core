import Foundation
import SwiftUI

/// How a media item fills its box. Callers map campaign JSON to this; the wrappers never parse
/// campaigns.
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

/// An image to show: where it loads from, how it fits, and the authored BlurHash drawn while it
/// loads and when it fails.
struct ImageSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
}

/// A Lottie animation to show: where it loads from, how it fits, the authored BlurHash drawn
/// until the animation is parsed, and its loop and autoplay.
struct LottieSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var loop: Bool = true
    var autoplay: Bool = true
}

/// The one normalized input the media wrappers take: callers convert campaign JSON into the kind
/// they render (`MediaImage` takes an `ImageSpec`, `MediaLottie` a `LottieSpec`). The wrappers
/// know nothing about campaigns, so there is deliberately no `fromJson` and no test for JSON
/// mapping.
enum MediaSpec: Sendable, Equatable, Hashable {
    case image(ImageSpec)
    case lottie(LottieSpec)

    var fit: MediaFit {
        switch self {
        case let .image(spec): spec.fit
        case let .lottie(spec): spec.fit
        }
    }

    var blurHash: String? {
        switch self {
        case let .image(spec): spec.blurHash
        case let .lottie(spec): spec.blurHash
        }
    }
}

extension Color {
    /// The shared dark backdrop drawn under media that has no still yet (D5): video before its
    /// first frame, Lottie while loading or failed. Surfaces with their own backdrop keep it;
    /// this is the wrapper default, so every tile degrades to the same dark box.
    static var mediaBackdrop: Color { Color(red: 0.10, green: 0.10, blue: 0.10) }
}

/// URLs a wrapper may fetch: non-blank, fully resolved (no `{{variable}}` template tokens left),
/// and parseable. Anything else renders the still below without fetching and without reporting —
/// absent content is not a failure (D5 reports failures; empty optionals stay silent).
func mediaUsableURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.contains("{{") else { return nil }
    return URL(string: trimmed)
}
