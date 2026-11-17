import CoreMotion
import Foundation

/// One skin `sensor` sample: SI units (rad/s gyroscope, m/s² accelerometer
/// including gravity) in the device's natural portrait frame — the same frame
/// Android reports, so skins read one shape on both platforms. `t` is ms
/// monotonic since the first `sensor.start` of the session.
struct GameMotionEvent: Equatable {
    var sensor: String
    var x: Double
    var y: Double
    var z: Double
    /// Milliseconds since the session's first sensor start.
    var t: Double

    var payload: [String: Any] {
        ["sensor": sensor, "x": x, "y": y, "z": z, "t": t]
    }
}

/// Streams CoreMotion data while the game is open and resumed (skin
/// `sensor.start`/`sensor.stop`). Each sensor runs at its own requested rate
/// (default 30 Hz, clamped 1…60); one timer ticks at the fastest rate and
/// each sensor emits when its own interval has elapsed.
///
/// Only the surface's visible, resumed lifetime streams: the presentation
/// suspends on lifecycle pause and stops everything on close. Pausing keeps
/// the requested sensors; stopping forgets them. No permission prompt — the
/// accelerometer and gyroscope need none.
///
/// Games run only where the core's iOS 17+ runtime gate allows.
@MainActor
final class GameMotionSource: NSObject {
    /// Sensor wire names, per the bridge contract.
    nonisolated static let gyroscopeName = "gyroscope"
    nonisolated static let accelerometerName = "accelerometer"

    /// Default rate when the skin sends no `hz`.
    nonisolated static let defaultHz = 30.0
    /// The skin's `hz` clamps into this range.
    nonisolated static let minHz = 1.0
    nonisolated static let maxHz = 60.0
    /// iOS reports acceleration in g with the opposite sign to Android; one
    /// multiply converts the units and matches the sign.
    nonisolated static let gToMS2 = -9.81

    /// Device capabilities for the `device.sensors` field of `init`.
    static var accelerometerAvailable: Bool { probe.isAccelerometerAvailable }
    static var gyroscopeAvailable: Bool { probe.isGyroAvailable }
    private nonisolated(unsafe) static let probe = CMMotionManager()

    /// Clamps a skin `hz` into range. Missing, non-finite, or non-positive
    /// values read as the default — never zero, never a crash.
    static func clampedHz(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return defaultHz }
        return min(maxHz, max(minHz, raw))
    }

    /// Converts one CoreMotion acceleration sample (g) to m/s², gravity
    /// included, matching Android's units and sign.
    static func accelerometerMS2(x: Double, y: Double, z: Double) -> (x: Double, y: Double, z: Double) {
        (x * gToMS2, y * gToMS2, z * gToMS2)
    }

    private struct ActiveSensor {
        var hz: Double
        /// Monotonic seconds of its last emission.
        var lastEmit: TimeInterval
    }

    private let manager = CMMotionManager()
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
            startUptime = ProcessInfo.processInfo.systemUptime
        }
        active[sensor] = ActiveSensor(hz: rate, lastEmit: ProcessInfo.processInfo.systemUptime - 1 / rate)
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
    }

    private func emitSamples() {
        guard let handler else { return }
        let now = ProcessInfo.processInfo.systemUptime
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
        default:
            return nil
        }
    }
}
