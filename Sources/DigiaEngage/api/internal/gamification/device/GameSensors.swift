import CoreMotion
import Foundation
import UIKit

/// One skin `motionSample`: SI units (rad/s gyroscope, m/s² accelerometer
/// including gravity, m/s² gravity and linear acceleration, unitless rotation
/// vector, µT magnetic field, hPa pressure, binary proximity) in the device's
/// natural portrait frame — the same frame Android reports, so skins read one
/// shape on both platforms. `t` is ms monotonic since the first `motion`
/// subscribe of the session. Single-value sensors (pressure, proximity) put
/// their reading in `x` and zero in `y`/`z`, like Android's missing axes.
struct GameMotionEvent: Equatable {
    var sensor: String
    var x: Double
    var y: Double
    var z: Double
    /// Milliseconds since the session's first sensor start.
    var t: Double

    var payload: [String: Any] {
        ["t": t, sensor: ["x": x, "y": y, "z": z]]
    }
}

/// Streams CoreMotion data while the game is open and resumed (skin
/// `motion` subscribe/unsubscribe). Each sensor runs at its own requested rate
/// (default 30 Hz, clamped 1…60); one timer ticks at the fastest rate and
/// each sensor emits when its own interval has elapsed.
///
/// Only the surface's visible, resumed lifetime streams: the presentation
/// suspends on lifecycle pause and stops everything on close. Pausing keeps
/// the requested sensors; stopping forgets them. Every sensor here is
/// permission-free — none is a body or location sensor, so the manifest
/// declares nothing for them, like Android's `GAME_SENSOR_TYPES`. Proximity
/// monitoring is enabled only while subscribed and restored on stop; `light`
/// has no public iOS API, so it is always unavailable.
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GameMotionSource: NSObject {
    /// Sensor wire names, per the bridge contract.
    nonisolated static let gyroscopeName = "gyroscope"
    nonisolated static let accelerometerName = "accelerometer"
    nonisolated static let gravityName = "gravity"
    nonisolated static let linearAccelerationName = "linear_acceleration"
    nonisolated static let rotationVectorName = "rotation_vector"
    nonisolated static let magneticFieldName = "magnetic_field"
    nonisolated static let pressureName = "pressure"
    nonisolated static let lightName = "light"
    nonisolated static let proximityName = "proximity"

    /// Every sensor the bridge intake accepts, in `init.device.sensors`
    /// order. Unknown names never reach here — the intake rejects them.
    nonisolated static let orderedSensorNames = [
        gyroscopeName, accelerometerName, gravityName, linearAccelerationName,
        rotationVectorName, magneticFieldName, pressureName, lightName, proximityName,
    ]

    /// Every sensor the bridge intake accepts.
    nonisolated static let allSensorNames: Set<String> = Set(orderedSensorNames)

    /// Default rate when the skin sends no `hz`.
    nonisolated static let defaultHz = 30.0
    /// The skin's `hz` clamps into this range.
    nonisolated static let minHz = 1.0
    nonisolated static let maxHz = 60.0
    /// iOS reports acceleration in g with the opposite sign to Android; one
    /// multiply converts the units and matches the sign.
    nonisolated static let gToMS2 = -9.81

    /// Device motion capability probe, shared so availability reads never
    /// start updates.
    private nonisolated(unsafe) static let probe = CMMotionManager()

    /// Clamps a skin `hz` into range. Missing, non-finite, or non-positive
    /// values read as the default — never zero, never a crash.
    static func clampedHz(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return defaultHz }
        return min(maxHz, max(minHz, raw))
    }

    /// Converts one CoreMotion acceleration sample (g) to m/s², matching
    /// Android's units and sign. Used for the accelerometer (gravity
    /// included), gravity and linear acceleration alike.
    static func accelerometerMS2(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double) {
        (x * gToMS2, y * gToMS2, z * gToMS2)
    }

    private struct ActiveSensor {
        var hz: Double
        /// Monotonic seconds of its last emission.
        var lastEmit: TimeInterval
    }

    private let manager = CMMotionManager()
    /// The barometer behind `pressure`. Its handler posts the latest hPa;
    /// the timer picks it up on the next tick.
    private let altimeter = CMAltimeter()
    /// The latest barometer reading in hPa (the altimeter reports kPa), or
    /// nil before the first delivery. Stays nil on devices without one.
    private var latestPressureHPA: Double?
    /// Whether this source turned proximity monitoring on; the host's prior
    /// setting is restored only in that case, never clobbered.
    private var proximityMonitoringOurs = false
    private var proximityWasMonitoring = false
    private var active: [String: ActiveSensor] = [:]
    private var handler: ((GameMotionEvent) -> Void)?
    private var startUptime: TimeInterval = 0
    private var timer: Timer?

    /// Reads availability for one sensor name. Defaults to the live hardware
    /// probe; tests inject a stub so the subscribe gate is deterministic
    /// without motion hardware.
    private let isAvailable: (String) -> Bool

    init(isAvailable: ((String) -> Bool)? = nil) {
        self.isAvailable = isAvailable ?? Self.hardwareAvailable(sensor:)
        super.init()
    }

    /// Live hardware availability for one sensor name. Unknown names are
    /// never available — the bridge intake already rejects them, so this
    /// only gates the hardware check.
    nonisolated static func hardwareAvailable(sensor: String) -> Bool {
        switch sensor {
        case gyroscopeName: return probe.isGyroAvailable
        case accelerometerName: return probe.isAccelerometerAvailable
        case gravityName, linearAccelerationName, rotationVectorName:
            return probe.isDeviceMotionAvailable
        case magneticFieldName: return probe.isMagnetometerAvailable
        case pressureName: return CMAltimeter.isRelativeAltitudeAvailable()
        case lightName:
            // iOS exposes no ambient-light API, so this sensor can never
            // stream — like a device without the hardware.
            return false
        case proximityName:
            // The proximity sensor ships on iPhones, not on iPads or Macs.
            return UIDevice.current.userInterfaceIdiom == .phone
        default: return false
        }
    }

    /// Sensors currently streaming. Tests read it to prove the subscribe
    /// gate starts nothing on failure.
    var activeSensorNames: Set<String> {
        Set(active.keys)
    }

    /// Starts one sensor at `hz`, replacing its rate when already started.
    /// Returns false — and streams nothing — when the sensor is unknown or its
    /// hardware is missing; the caller answers `error unsupported`.
    @discardableResult
    func start(sensor: String, hz: Double, handler: @escaping (GameMotionEvent) -> Void) -> Bool {
        let rate = Self.clampedHz(hz)
        guard isAvailable(sensor) else { return false }
        if active.isEmpty {
            startUptime = MonotonicClock.nowSeconds()
        }
        active[sensor] = ActiveSensor(hz: rate, lastEmit: MonotonicClock.nowSeconds() - 1 / rate)
        self.handler = handler
        restartHardware()
        return true
    }

    /// Starts every listed sensor at `hz`, but only after every one of them
    /// resolved available — a missing sensor fails the whole subscribe
    /// without starting any of them, like Android's `motion` handler.
    /// Returns false — and streams nothing — when any sensor is unavailable.
    @discardableResult
    func startAll(sensors: [String], hz: Double, handler: @escaping (GameMotionEvent) -> Void) -> Bool {
        for sensor in sensors {
            guard isAvailable(sensor) else { return false }
        }
        for sensor in sensors {
            start(sensor: sensor, hz: hz, handler: handler)
        }
        return true
    }

    /// Stops one sensor. Unknown names and idle calls are no-ops.
    func stop(sensor: String) {
        active.removeValue(forKey: sensor)
        if active.isEmpty {
            stopHardware()
            handler = nil
        } else {
            restartHardware()
        }
    }

    /// Stops every sensor. Safe to call when idle or twice in a row; the
    /// presentation calls it on close and web-view destroy.
    func stopAll() {
        active = [:]
        stopHardware()
        handler = nil
    }

    /// Suspends delivery on lifecycle pause, keeping the requested sensors.
    /// The presentation resumes them after.
    func suspend() {
        stopHardware()
    }

    /// Restarts delivery after a suspend, for the still-requested sensors.
    func resume() {
        guard !active.isEmpty else { return }
        restartHardware()
    }

    private func restartHardware() {
        stopHardware()
        if active[Self.accelerometerName] != nil {
            manager.accelerometerUpdateInterval = 1 / Self.maxHz
            manager.startAccelerometerUpdates()
        }
        if active[Self.gyroscopeName] != nil {
            manager.gyroUpdateInterval = 1 / Self.maxHz
            manager.startGyroUpdates()
        }
        if active[Self.gravityName] != nil || active[Self.linearAccelerationName] != nil
            || active[Self.rotationVectorName] != nil
        {
            manager.deviceMotionUpdateInterval = 1 / Self.maxHz
            manager.startDeviceMotionUpdates()
        }
        if active[Self.magneticFieldName] != nil {
            manager.magnetometerUpdateInterval = 1 / Self.maxHz
            manager.startMagnetometerUpdates()
        }
        if active[Self.pressureName] != nil {
            // No barometer, no delivery: the handler drops the error and
            // `latestPressureHPA` stays nil, so the tick emits nothing.
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let kpa = (data?.pressure)?.doubleValue else { return }
                Task { @MainActor [weak self] in self?.latestPressureHPA = kpa * 10 }
            }
        }
        if active[Self.proximityName] != nil, !proximityMonitoringOurs {
            let device = UIDevice.current
            proximityWasMonitoring = device.isProximityMonitoringEnabled
            device.isProximityMonitoringEnabled = true
            proximityMonitoringOurs = true
        }
        guard let fastest = active.values.map(\.hz).max(), fastest > 0 else { return }
        // Common modes so samples keep flowing during UI tracking.
        let timer = Timer(timeInterval: 1 / fastest, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in self?.emitSamples() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopHardware() {
        timer?.invalidate()
        timer = nil
        manager.stopAccelerometerUpdates()
        manager.stopGyroUpdates()
        manager.stopDeviceMotionUpdates()
        manager.stopMagnetometerUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        if proximityMonitoringOurs {
            UIDevice.current.isProximityMonitoringEnabled = proximityWasMonitoring
            proximityMonitoringOurs = false
        }
    }

    private func emitSamples() {
        guard let handler else { return }
        let now = MonotonicClock.nowSeconds()
        // Snapshot the keys: emitting writes each sensor's `lastEmit` back.
        for sensor in Array(active.keys) {
            guard var state = active[sensor],
                  now - state.lastEmit >= 1 / state.hz
            else { continue }
            guard let vector = read(sensor: sensor) else { continue }
            state.lastEmit = now
            active[sensor] = state
            handler(GameMotionEvent(
                sensor: sensor, x: vector.x, y: vector.y, z: vector.z,
                t: (now - startUptime) * 1000))
        }
    }

    private func read(sensor: String) -> (x: Double, y: Double, z: Double)? {
        switch sensor {
        case Self.accelerometerName:
            guard let acceleration = manager.accelerometerData?.acceleration else { return nil }
            return Self.accelerometerMS2(
                x: acceleration.x, y: acceleration.y, z: acceleration.z)
        case Self.gyroscopeName:
            guard let rate = manager.gyroData?.rotationRate else { return nil }
            return (rate.x, rate.y, rate.z)
        case Self.gravityName:
            guard let gravity = manager.deviceMotion?.gravity else { return nil }
            return Self.accelerometerMS2(x: gravity.x, y: gravity.y, z: gravity.z)
        case Self.linearAccelerationName:
            guard let user = manager.deviceMotion?.userAcceleration else { return nil }
            return Self.accelerometerMS2(x: user.x, y: user.y, z: user.z)
        case Self.rotationVectorName:
            // Android's rotation vector is the orientation quaternion's
            // (x, y, z); the scalar rides along implicitly.
            guard let quaternion = manager.deviceMotion?.attitude.quaternion else { return nil }
            return (quaternion.x, quaternion.y, quaternion.z)
        case Self.magneticFieldName:
            guard let field = manager.magnetometerData?.magneticField else { return nil }
            return (field.x, field.y, field.z)
        case Self.pressureName:
            guard let hpa = latestPressureHPA else { return nil }
            return (hpa, 0, 0)
        case Self.proximityName:
            // Binary where Android reports centimetres: near reads 0.
            return (UIDevice.current.proximityState ? 0 : 1, 0, 0)
        default:
            return nil
        }
    }
}
