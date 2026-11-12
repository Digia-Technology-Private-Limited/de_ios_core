import UIKit

/// Haptic styles the skin can request via `haptic{style}` (contract haptics, rule B-8.1).
enum GameHapticStyle: String {
    case light
    case medium
    case heavy
    case success
    case warning
}

/// Plays skin-requested haptics. Standalone from the bridge: the bridge parses
/// the `style` string, calls `play`, and logs when it returns false.
///
/// Ignored unless `haptics` is in the `sensors` the game opened with, and a
/// haptic within 30 ms of the previous one is dropped (rule B-8.1). iOS
/// exposes no haptics-capability API; every iPhone has a Taptic Engine and the
/// generators below no-op where unsupported (for example the simulator).
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GameHaptics {
    /// Minimum gap between two fired haptics (rule B-8.1: 30 ms).
    static let throttleInterval: TimeInterval = 0.030

    private let sensors: Set<String>
    private let now: () -> TimeInterval
    private let fire: @MainActor (GameHapticStyle) -> Void
    private var lastFiredAt: TimeInterval?

    init(
        sensors: Set<String> = [],
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        fire: @escaping @MainActor (GameHapticStyle) -> Void = GameHaptics.systemFire
    ) {
        self.sensors = sensors
        self.now = now
        self.fire = fire
    }

    /// Plays `style`, unless haptics are unavailable or throttled.
    /// Returns whether it fired, so the bridge can log drops.
    @discardableResult
    func play(_ style: GameHapticStyle) -> Bool {
        guard sensors.contains("haptics") else { return false }
        let timestamp = now()
        if let last = lastFiredAt, timestamp - last <= Self.throttleInterval { return false }
        lastFiredAt = timestamp
        fire(style)
        return true
    }

    private static func systemFire(_ style: GameHapticStyle) {
        switch style {
        case .light:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .medium:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .heavy:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case .success:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
