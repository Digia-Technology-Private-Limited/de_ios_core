import Foundation

/// The still a video shows before its first frame: the poster the dashboard cut (ADR-009).
///
/// Wire shape `{ url, placeholder: { type: "blurhash", blurHash }, videoUrl, frameMs }`; only
/// `url` and `placeholder` are read. Anything malformed is no poster, never an error.
struct VideoPoster: Equatable {
    let url: String
    /// Shown while the poster JPEG loads; only a `blurhash` placeholder with a hash carries one.
    let blurHash: String?

    /// Returns `nil` for a non-object value or a missing, blank or non-`http(s)` `url`.
    static func from(_ raw: Any?) -> VideoPoster? {
        guard let json = raw as? [String: Any],
              let url = (json["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        let blurHash = ImagePlaceholder.from(json["placeholder"] as? [String: Any])?.stillBlurHash
        return VideoPoster(url: url, blurHash: blurHash)
    }
}
