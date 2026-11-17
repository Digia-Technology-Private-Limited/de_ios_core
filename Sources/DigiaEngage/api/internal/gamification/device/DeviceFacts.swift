import Foundation
import UIKit

/// The `device` object sent in `init`, and the subset re-pushed
/// whenever it changes. The skin picks its own quality from `tier`; the SDK
/// never picks for it.
///
/// `soundAllowed` is always true: iOS exposes no mute-switch API, and web
/// audio is gated on a user gesture anyway. `hapticsAllowed` is the negation
/// of Reduce Motion — the closest public signal to the system haptics toggle —
/// re-read on every fire, so a settings change applies without relaunch.
struct GameDeviceInfo: Equatable, Sendable {
    var platform = "ios"
    var osVersion: String
    var sdkVersion: String
    var model: String
    var locale: String
    var timezone: String
    var hapticsAllowed: Bool
    var soundAllowed = true
    var reducedMotion: Bool
    var tier: String
    var ramMb: Int
    var cores: Int
    var thermal: String
    var lowPower: Bool
    var sensors: [String]

    /// The `init` `device` object.
    var payload: [String: Any] {
        [
            "platform": platform,
            "osVersion": osVersion,
            "sdkVersion": sdkVersion,
            "model": model,
            "locale": locale,
            "timezone": timezone,
            "hapticsAllowed": hapticsAllowed,
            "soundAllowed": soundAllowed,
            "reducedMotion": reducedMotion,
            "tier": tier,
            "ramMb": ramMb,
            "cores": cores,
            "thermal": thermal,
            "lowPower": lowPower,
            "sensors": sensors,
        ]
    }

    /// The `device` push subset: only these fields re-push on change.
    var pushPayload: [String: Any] {
        [
            "tier": tier,
            "thermal": thermal,
            "lowPower": lowPower,
            "reducedMotion": reducedMotion,
            "soundAllowed": soundAllowed,
        ]
    }

    /// Picks the skin tier from live facts: `minimal` when the device is
    /// constrained (Reduce Motion, Low Power, serious/critical heat, or under
    /// 3 GB RAM), `lite` when it is merely small (under 6 GB, under 6 cores,
    /// or fair heat), else `full`. Pure, so tests pin the boundaries.
    static func tier(
        ramMb: Int, cores: Int, thermal: String, lowPower: Bool, reducedMotion: Bool
    ) -> String {
        if reducedMotion || lowPower || thermal == "serious" || thermal == "critical"
            || ramMb < 3000
        {
            return "minimal"
        }
        if ramMb < 6000 || cores < 6 || thermal == "fair" {
            return "lite"
        }
        return "full"
    }

    /// Maps the thermal state to the `device.thermal` wire string.
    /// Unknown future states degrade to `nominal`, never throw.
    static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "nominal"
        }
    }

    /// BCP 47 tag (`en-IN`), the shape the contract's `locale` needs.
    static var deviceLocale: String {
        let identifier = Locale.current.identifier
        guard !identifier.isEmpty else { return "en" }
        return identifier.replacingOccurrences(of: "_", with: "-")
    }

    static func hapticsAllowedNow() -> Bool {
        !UIAccessibility.isReduceMotionEnabled
    }

    /// Reads the live device facts for `init`. No battery facts on iOS.
    @MainActor
    static func current(sdkVersion: String) -> GameDeviceInfo {
        let process = ProcessInfo.processInfo
        let ramMb = Int(process.physicalMemory / 1_024 / 1_024)
        let cores = process.activeProcessorCount
        let thermal = thermalName(process.thermalState)
        let lowPower = process.isLowPowerModeEnabled
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        var sensors: [String] = []
        if GameMotionSource.gyroscopeAvailable { sensors.append(GameMotionSource.gyroscopeName) }
        if GameMotionSource.accelerometerAvailable { sensors.append(GameMotionSource.accelerometerName) }
        return GameDeviceInfo(
            osVersion: UIDevice.current.systemVersion,
            sdkVersion: sdkVersion,
            model: deviceModel(),
            locale: deviceLocale,
            timezone: TimeZone.current.identifier,
            hapticsAllowed: !reducedMotion,
            reducedMotion: reducedMotion,
            tier: tier(
                ramMb: ramMb, cores: cores, thermal: thermal,
                lowPower: lowPower, reducedMotion: reducedMotion),
            ramMb: ramMb,
            cores: cores,
            thermal: thermal,
            lowPower: lowPower,
            sensors: sensors
        )
    }

    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
