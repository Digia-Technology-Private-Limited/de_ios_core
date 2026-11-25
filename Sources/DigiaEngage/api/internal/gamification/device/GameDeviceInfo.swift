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
    // The RAM, battery and CPU-cap cutoffs come from the backend's
    // `gamification.deviceTier.thresholds`; the defaults reproduce the
    // long-standing hardcoded numbers, so a missing section changes nothing.

    /// The server-driven cutoffs the level math reads; the defaults until a config applies.
    private static let measurementLock = NSLock()
    nonisolated(unsafe) private static var _measurement = GameMeasurementThresholds.defaults

    static var measurementThresholds: GameMeasurementThresholds { measurementLock.withLock { _measurement } }

    static func applyMeasurementThresholds(_ thresholds: GameMeasurementThresholds) {
        measurementLock.withLock { _measurement = thresholds }
    }

    /// The iOS-only pressure line: under a fifth of total RAM left counts as
    /// pressured. iOS exposes no heap ratio or low-memory threshold to apply
    /// `heapPressureRatio` / `availThresholdFactor` to, so those fields are
    /// parsed for parity but don't move this line.
    private static let availablePressureFraction = 0.2
    /// The iOS-only top CPU band: with no per-core tables the level comes
    /// from core count and RAM, and this boundary has no server field.
    private static let cpuHighRamGb = 5.5

    /// RAM level from total memory, one lower (never below 1) when the app has under a
    /// fifth of it left to use.
    static func memoryLevel(
        totalMb: Int, availableMb: Int?, thresholds: GameMeasurementThresholds = .defaults
    ) -> Int {
        guard totalMb > 0 else { return 0 }
        let gb = Double(totalMb) / 1_024
        let base: Int
        switch gb {
        case ..<thresholds.ramLowGb: base = 1
        case ..<thresholds.ramMidGb: base = 2
        case thresholds.ramHighGb...: base = 4
        default: base = 3
        }
        let pressured = availableMb.map { $0 > 0 && Double($0) < Double(totalMb) * availablePressureFraction } ?? false
        return pressured ? max(1, base - 1) : base
    }

    /// Battery level from the charge percentage; charging lowers each threshold.
    static func batteryLevel(
        percentage: Int?, charging: Bool, thresholds: GameMeasurementThresholds = .defaults
    ) -> Int {
        guard let pct = percentage else { return 0 }
        if pct >= thresholds.batteryHigh || (charging && pct >= thresholds.batteryHighCharging) { return 4 }
        if pct >= thresholds.batteryMid || (charging && pct >= thresholds.batteryMidCharging) { return 3 }
        if pct >= thresholds.batteryLow || (charging && pct >= thresholds.batteryLowCharging) { return 2 }
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
    /// The RAM caps are server-driven; the heap caps and score bands have no
    /// iOS API behind them and are parsed for parity only.
    static func cpuLevel(cores: Int, ramMb: Int, thresholds: GameMeasurementThresholds = .defaults) -> Int {
        guard cores > 0, ramMb > 0 else { return 0 }
        let gb = Double(ramMb) / 1_024
        if cores <= 2 || gb < thresholds.cpuCapRamLowGb { return 1 }
        if gb < thresholds.cpuCapRamMidGb { return 2 }
        if gb < cpuHighRamGb { return 3 }
        return 4
    }

    /// The synthesized `isLowRamDevice` fact: nil when the backend sent no
    /// `lowRamDeviceMb`, keeping the fact missing (today's iOS behavior).
    static func lowRamDevice(
        totalRamMb: Int, thresholds: GameMeasurementThresholds = .defaults
    ) -> Bool? {
        thresholds.lowRamDeviceMb.map { totalRamMb < $0 }
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
            readFacts(
                process: process, ramMb: ramMb, cores: cores, lowPower: lowPower,
                reducedMotion: reducedMotion, thresholds: measurementThresholds))
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
        process: ProcessInfo, ramMb: Int, cores: Int, lowPower: Bool, reducedMotion: Bool,
        thresholds: GameMeasurementThresholds = measurementThresholds
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
            "cpuLevel": .number(Double(cpuLevel(cores: cores, ramMb: ramMb, thresholds: thresholds))),
            "memoryLevel": .number(Double(memoryLevel(
                totalMb: ramMb, availableMb: availableMb, thresholds: thresholds))),
            "thermalLevel": .number(Double(thermalLevel(process.thermalState))),
            "batteryLevel": .number(Double(batteryLevel(
                percentage: batteryPct, charging: charging == true, thresholds: thresholds))),
        ]
        if let availableMb { facts["availableRamInMb"] = .number(Double(availableMb)) }
        if let batteryPct { facts["batteryPercentage"] = .number(Double(batteryPct)) }
        if let charging { facts["isCharging"] = .bool(charging) }
        if let lowRam = lowRamDevice(totalRamMb: ramMb, thresholds: thresholds) {
            facts["isLowRamDevice"] = .bool(lowRam)
        }
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
