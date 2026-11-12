import Foundation
import UIKit

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
}
