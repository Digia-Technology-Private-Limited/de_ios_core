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
    /// The rest mirror Android `GAME_SENSOR_TYPES` and are permission-free:
    /// none is a body or location sensor.
    case gravity = "gravity"
    case linearAcceleration = "linear_acceleration"
    case rotationVector = "rotation_vector"
    case magneticField = "magnetic_field"
    case pressure = "pressure"
    case light = "light"
    case proximity = "proximity"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationSkinSensor(rawValue: value ?? "") ?? .unknown
    }
}
