import Foundation

/// What the SDK renders while an image loads.
///
/// Mirrors the dashboard's `placeholder` object in the SDUI payload
/// (`{ type: "blurhash", blurHash }`). Modelled as a tagged object rather than a
/// bare hash so new strategies (loader, shimmer, …) can be added without a
/// breaking payload change — today only `.blurhash` carries data and is rendered.
enum ImagePlaceholderType: String {
    case blurhash
    case loader
    case shimmer
}

struct ImagePlaceholder: Equatable {
    let type: ImagePlaceholderType
    /// BlurHash string; present when `type` is `.blurhash`.
    let blurHash: String?

    /// Parses a `placeholder` object from an untyped JSON map (nudge/carousel
    /// payloads). Returns `nil` when absent or the `type` is missing/unknown,
    /// so callers treat it as "no placeholder".
    static func from(_ json: [String: Any]?) -> ImagePlaceholder? {
        guard let json,
              let rawType = json["type"] as? String,
              let type = ImagePlaceholderType(rawValue: rawType)
        else { return nil }
        let hash = (json["blurHash"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ImagePlaceholder(type: type, blurHash: hash)
    }

    /// Same parse for the survey config's typed `JSONValue` maps.
    static func from(_ json: [String: JSONValue]?) -> ImagePlaceholder? {
        guard let json,
              let rawType = SurveyParse.string(json["type"]),
              let type = ImagePlaceholderType(rawValue: rawType)
        else { return nil }
        let hash = SurveyParse.string(json["blurHash"]).flatMap { $0.isEmpty ? nil : $0 }
        return ImagePlaceholder(type: type, blurHash: hash)
    }
}
