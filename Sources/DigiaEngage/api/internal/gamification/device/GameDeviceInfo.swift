import Foundation
import os
import UIKit

/// The `device` object sent in `init`, and the subset re-pushed
/// whenever it changes. `tier` (`high`, `mid` or `low`) comes from the backend's
/// `gamification.deviceTier` rules evaluated over `facts`; the skin picks its own
/// quality from it.
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
    /// The raw facts and levels the tier rules read, named as in the backend rules.
    var facts: [String: TierOperand] = [:]

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
            "facts": facts.mapValues(\.json),
        ]
    }

    /// The `device` push subset: only these fields re-push on change.
    var pushPayload: [String: Any] {
        [
            "tier": tier,
            "thermal": thermal,
            "lowPower": lowPower,
            "reducedMotion": reducedMotion,
            "hapticsAllowed": hapticsAllowed,
            "soundAllowed": soundAllowed,
        ]
    }

    // Levels: 0 unknown, 1 low, 2 average, 3 high, 4 excellent, after grofers/droid-dex.
    // The thresholds match Android's `GameDeviceFacts`.

    /// RAM level from total memory, one lower (never below 1) when the app has under a
    /// fifth of it left to use.
    static func memoryLevel(totalMb: Int, availableMb: Int?) -> Int {
        guard totalMb > 0 else { return 0 }
        let gb = Double(totalMb) / 1_024
        let base: Int
        switch gb {
        case ..<2.8: base = 1
        case ..<6.9: base = 2
        case 10.5...: base = 4
        default: base = 3
        }
        let pressured = availableMb.map { $0 > 0 && Double($0) < Double(totalMb) * 0.2 } ?? false
        return pressured ? max(1, base - 1) : base
    }

    /// Battery level from the charge percentage; charging lowers each threshold.
    static func batteryLevel(percentage: Int?, charging: Bool) -> Int {
        guard let pct = percentage else { return 0 }
        if pct >= 80 || (charging && pct >= 70) { return 4 }
        if pct >= 55 || (charging && pct >= 50) { return 3 }
        if pct >= 40 || (charging && pct >= 35) { return 2 }
        return 1
    }

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: 4
        case .fair: 3
        case .serious: 2
        case .critical: 1
        @unknown default: 0
        }
    }

    /// An approximation: iOS exposes no per-core frequency or design, so the level comes
    /// from core count and RAM, which track the chip generation on iPhones.
    static func cpuLevel(cores: Int, ramMb: Int) -> Int {
        guard cores > 0, ramMb > 0 else { return 0 }
        let gb = Double(ramMb) / 1_024
        if cores <= 2 || gb < 2.8 { return 1 }
        if gb < 3.6 { return 2 }
        if gb < 5.5 { return 3 }
        return 4
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

    /// Reads the live device facts for `init`. Every read is permission-free; one that is
    /// unavailable is left out of `facts` (unknown), never guessed.
    @MainActor
    static func current(sdkVersion: String) -> GameDeviceInfo {
        let process = ProcessInfo.processInfo
        let ramMb = Int(process.physicalMemory / 1_024 / 1_024)
        let cores = process.activeProcessorCount
        let thermal = thermalName(process.thermalState)
        let lowPower = process.isLowPowerModeEnabled
        let reducedMotion = UIAccessibility.isReduceMotionEnabled
        var sensors: [String] = []
        for name in GameMotionSource.orderedSensorNames
        where GameMotionSource.hardwareAvailable(sensor: name) {
            sensors.append(name)
        }
        let facts = GameDeviceTier.scored(
            readFacts(process: process, ramMb: ramMb, cores: cores, lowPower: lowPower, reducedMotion: reducedMotion))
        return GameDeviceInfo(
            osVersion: UIDevice.current.systemVersion,
            sdkVersion: sdkVersion,
            model: deviceModel(),
            locale: deviceLocale,
            timezone: TimeZone.current.identifier,
            hapticsAllowed: !reducedMotion,
            reducedMotion: reducedMotion,
            tier: GameDeviceTier.evaluate(facts),
            ramMb: ramMb,
            cores: cores,
            thermal: thermal,
            lowPower: lowPower,
            sensors: sensors,
            facts: facts
        )
    }

    @MainActor
    private static func readFacts(
        process: ProcessInfo, ramMb: Int, cores: Int, lowPower: Bool, reducedMotion: Bool
    ) -> [String: TierOperand] {
        // The app's remaining memory budget; 0 means unavailable (simulator, older OS).
        let availableBytes = os_proc_available_memory()
        let availableMb: Int? = availableBytes > 0 ? Int(availableBytes / 1_024 / 1_024) : nil

        // Battery reads need monitoring on; restore the host's setting afterwards.
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        let rawLevel = device.batteryLevel
        let state = device.batteryState
        device.isBatteryMonitoringEnabled = wasMonitoring
        let batteryPct: Int? = rawLevel >= 0 ? Int((rawLevel * 100).rounded()) : nil
        let charging: Bool? = switch state {
        case .charging, .full: true
        case .unplugged: false
        default: nil
        }

        var facts: [String: TierOperand] = [
            "totalRamInMb": .number(Double(ramMb)),
            "isPowerSaveMode": .bool(lowPower),
            "thermalStatus": .string(thermalName(process.thermalState)),
            "isReduceMotionEnabled": .bool(reducedMotion),
            "cpuCores": .number(Double(cores)),
            "cpuLevel": .number(Double(cpuLevel(cores: cores, ramMb: ramMb))),
            "memoryLevel": .number(Double(memoryLevel(totalMb: ramMb, availableMb: availableMb))),
            "thermalLevel": .number(Double(thermalLevel(process.thermalState))),
            "batteryLevel": .number(Double(batteryLevel(percentage: batteryPct, charging: charging == true))),
        ]
        if let availableMb { facts["availableRamInMb"] = .number(Double(availableMb)) }
        if let batteryPct { facts["batteryPercentage"] = .number(Double(batteryPct)) }
        if let charging { facts["isCharging"] = .bool(charging) }
        return facts
    }

    private static func deviceModel() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
