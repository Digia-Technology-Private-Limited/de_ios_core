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

enum GamificationOutcomeKind: String, Equatable, Sendable {
    case reward = "reward"
    case extraPlay = "extraPlay"
    case betterLuck = "betterLuck"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationOutcomeKind(rawValue: value ?? "") ?? .unknown
    }
}

enum GamificationRewardType: String, Equatable, Sendable {
    case coupon = "coupon"
    case currency = "currency"
    case perk = "perk"
    case unknown = "unknown"

    init(wire value: String?) {
        self = GamificationRewardType(rawValue: value ?? "") ?? .unknown
    }
}

enum GamificationPlayRefusal: String, Equatable, Sendable {
    case notVerified = "notVerified"
    case notFound = "notFound"
    case expired = "expired"
    case alreadyPlayed = "alreadyPlayed"
    case notPlayable = "notPlayable"
    case busy = "busy"
    /// Client-only: a refusal the server never sends. Also the bucket for a
    /// refusal string the server sent that this SDK does not know — the play
    /// already happened, so degrading to a named reason beats failing the
    /// outcome. `busy` never reaches the skin (T8 retries it).
    case unavailable = "unavailable"

    init(wire value: String?) {
        self = GamificationPlayRefusal(rawValue: value ?? "") ?? .unavailable
    }
}
