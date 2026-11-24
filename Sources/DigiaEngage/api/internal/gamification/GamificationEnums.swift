import Foundation

/// Wire values shared with the backend.
///
/// Every `unknown` parses from any unrecognised wire value, and the campaign
/// is skipped with a log at the parse site. Nothing here throws.
enum GamificationEntryKind: String, Equatable, Sendable {
    case direct = "direct"
    case inlineTeaser = "inlineTeaser"
    case floating = "floating"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationEntryKind(rawValue: value ?? "") ?? .unknown
    }
}

enum GamificationSkinSensor: String, Equatable, Sendable {
    case haptics = "haptics"
    case gyroscope = "gyroscope"
    case accelerometer = "accelerometer"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationSkinSensor(rawValue: value ?? "") ?? .unknown
    }
}
