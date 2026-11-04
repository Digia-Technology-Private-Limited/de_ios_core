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

/// The transport-level request options travelling with a spec: headers the fetcher
/// sends (images; video players authenticate at the campaign layer, not here).
struct MediaRequest: Sendable, Equatable, Hashable {
    var headers: [String: String] = [:]
}

/// The `User-Agent` the SDK image requests send.
let DIGIA_IMAGE_USER_AGENT = "DigiaEngage/1.0 (iOS)"

/// A `MediaRequest` carrying the SDK image `User-Agent`: what the UA opt-ins become.
func digiaUserAgentRequest() -> MediaRequest {
    MediaRequest(headers: ["User-Agent": DIGIA_IMAGE_USER_AGENT])
}

/// How a video shows and sounds: loop, autoplay, mute state, unmuted level and start
/// position. The floater's configured volume lives here, not in an orchestrator
/// direct-write (so a take-over reset never leaks one borrow's level into the next).
struct Playback: Sendable, Equatable, Hashable {
    var loop: Bool = false
    var autoplay: Bool = true
    var muted: Bool = true
    var volume: Float = 1
    var startMs: Int = 0
}

/// The authored loading display for an image, parsed from the payload's placeholder
/// type. R1 carries it in the contract (owner: kept); surfaces render it in R2 —
/// wrappers draw BlurHash-or-backdrop until then, never this.
enum MediaLoadingDisplay: Sendable, Equatable, Hashable {
    case none
    case loader
    case shimmer
}

/// An image showing: where it loads from, how it fits, its stills, its transport
/// options and its decoder opt-ins. GIFs animate with no opt-in; `animatedGif`
/// records the authored flag for parity.
struct ImageSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var request: MediaRequest = MediaRequest()
    var animatedGif: Bool = false
    /// Crossfade the loaded image in (per-image opt-in, applied by R2).
    var crossfade: Bool = false
    var loadingDisplay: MediaLoadingDisplay = .none
}

/// A video showing: where it loads from, how it fits, its stills, its transport
/// options, its authored poster and its playback.
struct VideoSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var request: MediaRequest = MediaRequest()
    var posterURL: String? = nil
    var playback: Playback = Playback()
}

/// A Lottie showing: where it loads from, how it fits, its stills, its transport
/// options and its loop/autoplay.
struct LottieSpec: Sendable, Equatable, Hashable {
    var url: String
    var fit: MediaFit = .cover
    var blurHash: String? = nil
    var request: MediaRequest = MediaRequest()
    var loop: Bool = true
    var autoplay: Bool = true
}

/// The one normalized input the media wrappers take (D1, D13, sealed D15):
/// callers convert campaign JSON into the kind they render; the wrappers know
/// nothing about campaigns (D4), so there is deliberately no `fromJson` and no
/// test for JSON mapping. Views stay kind-specific — `MediaImage(spec:
/// ImageSpec)`, `MediaLottie(spec: LottieSpec)`, `MediaVideo(state:)` over a
/// `VideoSpec` — and read only their kind's fields.
///
/// Common to every kind: `url`, `fit`, the authored blurred preview
/// (`blurHash`, drawn while loading and on error, D5) and the transport
/// `request`. Everything else is kind-specific.
enum MediaSpec: Sendable, Equatable, Hashable {
    case image(ImageSpec)
    case video(VideoSpec)
    case lottie(LottieSpec)

    var url: String {
        switch self {
        case let .image(spec): spec.url
        case let .video(spec): spec.url
        case let .lottie(spec): spec.url
        }
    }

    var fit: MediaFit {
        switch self {
        case let .image(spec): spec.fit
        case let .video(spec): spec.fit
        case let .lottie(spec): spec.fit
        }
    }

    var blurHash: String? {
        switch self {
        case let .image(spec): spec.blurHash
        case let .video(spec): spec.blurHash
        case let .lottie(spec): spec.blurHash
        }
    }

    var request: MediaRequest {
        switch self {
        case let .image(spec): spec.request
        case let .video(spec): spec.request
        case let .lottie(spec): spec.request
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
