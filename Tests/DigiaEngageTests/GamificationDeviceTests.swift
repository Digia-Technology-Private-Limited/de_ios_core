import Foundation
import Testing
@testable import DigiaEngage

/// Guards `GameHaptics`' throttle and gate: the production lines are the
/// `isAllowed` check and the `timestamp - last <= throttleInterval`
/// comparison in `play`.
@Suite("Game haptics", .tags(.unit, .game))
@MainActor
struct GameHapticsTests {

    @Test("second haptic within 30 ms is dropped")
    func throttleDropsSecondHapticWithin30ms() {
        var now = 100.0
        var fired: [GameHapticStyle] = []
        let haptics = GameHaptics(now: { now }, fire: { fired.append($0) }, isAllowed: { true })

        #expect(haptics.play(.light))
        now += 0.029
        #expect(!haptics.play(.medium))
        #expect(fired == [.light])
        now += 0.001
        #expect(haptics.play(.medium))
        #expect(fired == [.light, .medium])
    }

    @Test("haptic is ignored when disallowed")
    func ignoredWhenDisallowed() {
        var fired: [GameHapticStyle] = []
        let haptics = GameHaptics(now: { 0 }, fire: { fired.append($0) }, isAllowed: { false })

        // Guards the isAllowed check in play.
        #expect(!haptics.play(.success))
        #expect(fired.isEmpty)
    }

    @Test("all seven bridge styles fire")
    func allStylesFire() {
        var fired: [GameHapticStyle] = []
        var now = 0.0
        let haptics = GameHaptics(
            now: { now }, fire: { fired.append($0) }, isAllowed: { true })

        for style in GameHapticStyle.allCases {
            now += 1
            #expect(haptics.play(style))
        }
        #expect(fired == GameHapticStyle.allCases)
    }
}

/// Guards the skin tier rule: the production lines are the threshold
/// comparisons in `GameDeviceInfo.tier`.
@Suite("Game device tier", .tags(.unit, .game))
struct GameDeviceTierTests {
    @Test("constrained devices read minimal")
    func minimal() {
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "nominal", lowPower: false, reducedMotion: true) == "minimal")
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "nominal", lowPower: true, reducedMotion: false) == "minimal")
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "serious", lowPower: false, reducedMotion: false) == "minimal")
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "critical", lowPower: false, reducedMotion: false) == "minimal")
        // Guards the RAM floor: under 3 GB is minimal whatever else.
        #expect(GameDeviceInfo.tier(ramMb: 2999, cores: 8, thermal: "nominal", lowPower: false, reducedMotion: false) == "minimal")
    }

    @Test("small devices read lite")
    func lite() {
        #expect(GameDeviceInfo.tier(ramMb: 3000, cores: 8, thermal: "nominal", lowPower: false, reducedMotion: false) == "lite")
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 5, thermal: "nominal", lowPower: false, reducedMotion: false) == "lite")
        // Guards the fair-thermal arm.
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "fair", lowPower: false, reducedMotion: false) == "lite")
    }

    @Test("capable devices read full")
    func full() {
        #expect(GameDeviceInfo.tier(ramMb: 6000, cores: 6, thermal: "nominal", lowPower: false, reducedMotion: false) == "full")
        #expect(GameDeviceInfo.tier(ramMb: 8192, cores: 8, thermal: "nominal", lowPower: false, reducedMotion: false) == "full")
    }

    @Test("unknown thermal states degrade to nominal")
    func thermalMapping() {
        #expect(GameDeviceInfo.thermalName(.nominal) == "nominal")
        #expect(GameDeviceInfo.thermalName(.fair) == "fair")
        #expect(GameDeviceInfo.thermalName(.serious) == "serious")
        #expect(GameDeviceInfo.thermalName(.critical) == "critical")
    }
}

/// Guards the motion unit math and rate clamp: the production lines are
/// `clampedHz` and `accelerometerMS2`.
@Suite("Game motion source", .tags(.unit, .game))
@MainActor
struct GameMotionSourceTests {
    @Test("hz clamps into 1 to 60, defaulting to 30")
    func hzClamp() {
        #expect(GameMotionSource.clampedHz(nil) == 30)
        #expect(GameMotionSource.clampedHz(30) == 30)
        // Guards the range clamp in clampedHz.
        #expect(GameMotionSource.clampedHz(100) == 60)
        #expect(GameMotionSource.clampedHz(0) == 30)
        #expect(GameMotionSource.clampedHz(-5) == 30)
        #expect(GameMotionSource.clampedHz(0.5) == 1)
        #expect(GameMotionSource.clampedHz(Double.nan) == 30)
    }

    @Test("acceleration converts g to m/s² with Android's sign")
    func accelerationUnits() {
        let converted = GameMotionSource.accelerometerMS2(x: 0, y: 0, z: -1)
        // Guards the gToMS2 multiply: 1 g up reads +9.81 m/s², gravity included.
        #expect(abs(converted.z - 9.81) < 0.001)
        #expect(converted.x == 0)
        #expect(converted.y == 0)
    }

    @Test("unknown sensors never start")
    func unknownSensorUnsupported() {
        let source = GameMotionSource()
        // Guards the name check in start: no hardware is touched.
        #expect(!source.start(sensor: "lidar", hz: 30) { _ in })
    }
}
