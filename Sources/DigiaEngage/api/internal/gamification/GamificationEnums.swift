import Foundation

/// Wire mirror of the backend gamification contracts
/// (`ai_docs/gamification/eng/README.md` "Shared contracts"). The one mirror
/// file the ERD requires — no second copy lives anywhere else in this core.
///
/// Every `unknown` parses from any unrecognised wire value, and the campaign
/// is skipped with a log at the parse site. Nothing here throws.
enum GamificationFormat: String, Equatable, Sendable {
    case scratchCard = "scratchCard"
    case spinWheel = "spinWheel"
    case rewardChest = "rewardChest"
    case slotMachine = "slotMachine"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationFormat(rawValue: value ?? "") ?? .unknown
    }
}

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
