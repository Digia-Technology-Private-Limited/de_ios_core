import CoreMotion
import Foundation
import UIKit

/// One `motion` sample (contract motion): `t` is milliseconds since `start`,
/// each vector present only when its sensor was started.
struct GameMotionSample: Equatable {
    struct Vector: Equatable {
        var x: Double
        var y: Double
        var z: Double
    }

    var t: Double
    var gyroscope: Vector?
    var accelerometer: Vector?
}

/// Streams CoreMotion data at 30 Hz while the game is open and foregrounded
/// (contract motion, rule B-8.2). Standalone from the bridge: the bridge calls
/// `start` on `startMotion`, `stop` on `stopMotion`, pause, or close, and
/// encodes each sample as a `motion` message.
///
/// No permission prompt: accelerometer and gyroscope need none at 30 Hz.
/// Stops itself when the app backgrounds; the bridge restarts it on resume
/// when the skin still wants motion.
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GameMotionSource: NSObject {
    /// Samples per second (contract motion: 30 Hz).
    static let sampleInterval: TimeInterval = 1.0 / 30.0
    /// iOS reports acceleration in g with the opposite sign to Android; one
    /// multiply converts the units and matches the sign (contract motion).
    static let gToMS2 = -9.81

    /// Device motion capabilities, for the `sensors` field of `init`
    /// (the manifest sensors this device has).
    static var accelerometerAvailable: Bool { probe.isAccelerometerAvailable }
    static var gyroscopeAvailable: Bool { probe.isGyroAvailable }
    private static let probe = CMMotionManager()

    /// Converts one CoreMotion acceleration sample (g) to m/s², gravity
    /// included, matching Android's units and sign.
    static func accelerometerMS2(x: Double, y: Double, z: Double) -> GameMotionSample.Vector {
        GameMotionSample.Vector(x: x * gToMS2, y: y * gToMS2, z: z * gToMS2)
    }

    private let manager = CMMotionManager()
    private var activeSensors: Set<String> = []
    private var handler: ((GameMotionSample) -> Void)?
    private var startUptimeMs: Double = 0
    private var timer: Timer?

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    /// Starts streaming the requested sensors that exist on this device.
    /// Sensors outside the manifest, or not on the device, are ignored.
    /// A call while already streaming restarts cleanly.
    func start(sensors: Set<String>, handler: @escaping (GameMotionSample) -> Void) {
        stop()
        let useAccelerometer = sensors.contains("accelerometer") && manager.isAccelerometerAvailable
        let useGyroscope = sensors.contains("gyroscope") && manager.isGyroAvailable
        guard useAccelerometer || useGyroscope else { return }
        activeSensors = sensors
        self.handler = handler
        startUptimeMs = ProcessInfo.processInfo.systemUptime * 1000
        if useAccelerometer {
            manager.accelerometerUpdateInterval = Self.sampleInterval
            manager.startAccelerometerUpdates()
        }
        if useGyroscope {
            manager.gyroUpdateInterval = Self.sampleInterval
            manager.startGyroUpdates()
        }
        // Common modes so samples keep flowing during UI tracking.
        let timer = Timer(timeInterval: Self.sampleInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in self?.emitSample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops streaming. Safe to call when idle or twice in a row; the bridge
    /// calls it on `stopMotion`, pause, close, and web-view destroy.
    func stop() {
        timer?.invalidate()
        timer = nil
        handler = nil
        activeSensors = []
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
    }

    private func emitSample() {
        guard let handler else { return }
        let elapsedMs = ProcessInfo.processInfo.systemUptime * 1000 - startUptimeMs
        var sample = GameMotionSample(t: elapsedMs)
        if activeSensors.contains("accelerometer"),
           let acceleration = manager.accelerometerData?.acceleration
        {
            sample.accelerometer = Self.accelerometerMS2(
                x: acceleration.x, y: acceleration.y, z: acceleration.z)
        }
        if activeSensors.contains("gyroscope"),
           let rate = manager.gyroData?.rotationRate
        {
            sample.gyroscope = GameMotionSample.Vector(x: rate.x, y: rate.y, z: rate.z)
        }
        handler(sample)
    }

    @objc private nonisolated func handleBackground() {
        Task { @MainActor [weak self] in self?.stop() }
    }
}
