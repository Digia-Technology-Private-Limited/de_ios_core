import UIKit

/// Haptic styles the skin can request via `haptics{style}` (bridge v1).
enum GameHapticStyle: String, CaseIterable {
    case selection
    case light
    case medium
    case heavy
    case success
    case warning
    case error
}

/// Plays skin-requested haptics. Standalone from the bridge: the bridge parses
/// the `style` string, calls `play`, and logs when it returns false.
///
/// Gated on `isAllowed` — false when the device or the user disallows haptics
/// (Reduce Motion is the closest public signal; there is no API for the system
/// haptics toggle) — and a haptic within 30 ms of the previous one is dropped.
/// iOS exposes no haptics-capability API; every iPhone has a Taptic Engine and
/// the generators below no-op where unsupported (for example the simulator).
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GameHaptics {
    /// Minimum gap between two fired haptics (30 ms).
    static let throttleInterval: TimeInterval = 0.030

    private let now: () -> TimeInterval
    private let fire: @MainActor (GameHapticStyle) -> Void
    private let isAllowed: @MainActor () -> Bool
    private var lastFiredAt: TimeInterval?

    init(
        now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate },
        fire: @escaping @MainActor (GameHapticStyle) -> Void = GameHaptics.systemFire,
        isAllowed: @escaping @MainActor () -> Bool = { GameDeviceInfo.hapticsAllowedNow() }
    ) {
        self.now = now
        self.fire = fire
        self.isAllowed = isAllowed
    }

    /// Plays `style`, unless haptics are disallowed or throttled.
    /// Returns whether it fired, so the bridge can log drops.
    @discardableResult
    func play(_ style: GameHapticStyle) -> Bool {
        guard isAllowed() else { return false }
        let timestamp = now()
        if let last = lastFiredAt, timestamp - last < Self.throttleInterval { return false }
        lastFiredAt = timestamp
        fire(style)
        return true
    }

    private static func systemFire(_ style: GameHapticStyle) {
        switch style {
        case .selection:
            UISelectionFeedbackGenerator().selectionChanged()
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
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}
