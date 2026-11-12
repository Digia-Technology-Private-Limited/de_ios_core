import Foundation
import UIKit

/// Tier names from the skin rule (ERD device facts and tier). The SDK never
/// picks the tier — the skin does from the facts below; `DeviceFacts.pickTier`
/// mirrors the rule for reference.
enum GameTier: String {
    case minimal
    case lite
    case full
}

/// Facts about the device sent in `init` as `device` (ERD device facts and
/// tier, rule B-8.4). No battery facts on iOS.
struct GameDeviceFacts: Equatable, Encodable {
    var ramMb: Int
    var cores: Int
    var lowRam: Bool
    var powerSave: Bool
    var thermal: String
    var reducedMotion: Bool

    /// The same facts as a JSON dictionary, for serialization-built payloads.
    var jsonDictionary: [String: Any] {
        [
            "ramMb": ramMb,
            "cores": cores,
            "lowRam": lowRam,
            "powerSave": powerSave,
            "thermal": thermal,
            "reducedMotion": reducedMotion,
        ]
    }
}

/// Builds `GameDeviceFacts` from the device (rule B-8.4).
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
enum DeviceFacts {
    /// Below this the skin rule picks `minimal`.
    static let minimalRamMb = 2_500
    /// Below this the skin rule picks `lite`.
    static let liteRamMb = 4_500
    /// At or below this core count the skin rule picks `lite`.
    static let smallCoreCount = 4

    /// Reads the live device facts for `init`.
    static func build() -> GameDeviceFacts {
        GameDeviceFacts(
            ramMb: Int(ProcessInfo.processInfo.physicalMemory / 1_024 / 1_024),
            cores: ProcessInfo.processInfo.activeProcessorCount,
            // iOS exposes no low-RAM flag; the rule sends false.
            lowRam: false,
            powerSave: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermal: thermalName(ProcessInfo.processInfo.thermalState),
            reducedMotion: UIAccessibility.isReduceMotionEnabled
        )
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

    /// Mirrors the skin tier rule for reference; the SDK sends the facts and
    /// the skin picks. iOS sends no battery facts, so the battery clause of
    /// the rule can never trigger here.
    static func pickTier(_ facts: GameDeviceFacts) -> GameTier {
        if facts.lowRam || facts.ramMb < minimalRamMb
            || facts.thermal == "serious" || facts.thermal == "critical"
        {
            return .minimal
        }
        if facts.powerSave || facts.ramMb < liteRamMb
            || facts.cores <= smallCoreCount || facts.thermal == "fair"
        {
            return .lite
        }
        return .full
    }
}
