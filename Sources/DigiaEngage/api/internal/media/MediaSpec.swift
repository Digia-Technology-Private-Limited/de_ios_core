import Foundation
import SwiftUI

/// How a `MediaSpec`'s content fills its box. The wrapper-local counterpart of campaign fit
/// values: callers map campaign JSON to this (D4); the wrappers never parse campaigns.
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

/// The one normalized input every media wrapper takes (D1). Callers convert campaign JSON into
/// this; the wrappers know nothing about campaigns (D4), so there is deliberately no `fromJson`
/// and no test for JSON mapping.
///
/// - `url`: the image, video or Lottie URL.
/// - `fit`: how the content fills its box.
/// - `blurHash`: the authored blurred preview, drawn while loading and on error (D5).
/// - `posterURL`: video only: a campaign-supplied thumbnail/poster URL (D6), drawn until the
///   first frame. Posters are images, so they render through `MediaImage`.
/// - `loop`: whether a video or Lottie loops.
/// - `autoplay`: whether a video or Lottie starts on its own.
/// - `muted`: whether a video starts silent.
/// - `startMs`: where a video starts, in milliseconds. The use site coerces it to >= 0;
///   it is never an index.
struct MediaSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var posterURL: String? = nil
    var loop: Bool = false
    var autoplay: Bool = true
    var muted: Bool = true
    var startMs: Int = 0
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
