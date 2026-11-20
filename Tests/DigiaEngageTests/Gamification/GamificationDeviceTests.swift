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

/// Guards the device-tier rules: mirrors Android's `GameDeviceTierTest`.
@Suite("Game device tier", .tags(.unit, .game))
struct GameDeviceTierTests {
    /// A flagship on a good day: every level high, nothing flagged.
    private let flagship: [String: TierOperand] = [
        "isLowRamDevice": .bool(false),
        "isSystemLowOnMemory": .bool(false),
        "isPowerSaveMode": .bool(false),
        "isReduceMotionEnabled": .bool(false),
        "cpuLevel": .number(4),
        "memoryLevel": .number(4),
        "thermalLevel": .number(4),
        "batteryLevel": .number(4),
    ]

    private func tier(_ facts: [String: TierOperand], _ config: DeviceTierConfig = .default) -> String {
        GameDeviceTier.evaluate(GameDeviceTier.scored(facts, config: config), config: config)
    }

    private func with(_ changes: [String: TierOperand]) -> [String: TierOperand] {
        flagship.merging(changes) { _, new in new }
    }

    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func config(rules: String) -> DeviceTierConfig {
        DeviceTierConfig.parse(json(#"{"weights":{"cpuLevel":1},"rules":"# + rules + #","fallback":"low"}"#))
    }

    // MARK: default rules

    @Test("a flagship is high")
    func flagshipHigh() {
        #expect(tier(flagship) == "high")
    }

    @Test("one low flag drops a flagship to low, because low is checked first")
    func lowFlag() {
        #expect(tier(with(["isPowerSaveMode": .bool(true)])) == "low")
        #expect(tier(with(["thermalLevel": .number(1)])) == "low")
    }

    @Test("a strong device on a flat battery is mid, not high")
    func flatBattery() {
        #expect(tier(with(["batteryLevel": .number(1)])) == "mid")
    }

    @Test("average levels are mid")
    func average() {
        #expect(tier(with(["cpuLevel": .number(2), "memoryLevel": .number(2), "thermalLevel": .number(2)])) == "mid")
    }

    @Test("no facts at all falls back to low")
    func empty() {
        #expect(tier([:]) == "low")
    }

    // MARK: performanceScore

    @Test("score is the weighted mean of known levels, skipping unknown ones")
    func score() {
        // cpu 4x3 + memory 2x3 = 18 over weight 6; thermal unknown (0), battery missing.
        let scored = GameDeviceTier.scored(
            ["cpuLevel": .number(4), "memoryLevel": .number(2), "thermalLevel": .number(0)], config: .default)
        #expect(scored["performanceScore"] == .number(3))
        #expect(GameDeviceTier.scored([:], config: .default)["performanceScore"] == .number(0))
    }

    // MARK: rule semantics

    @Test("any needs one condition, all needs every one")
    func anyAll() {
        let c = config(rules: #"[{"tier":"high","all":[{"fact":"a","eq":1},{"fact":"b","eq":1}]},{"tier":"mid","any":[{"fact":"a","eq":1},{"fact":"b","eq":1}]}]"#)
        #expect(GameDeviceTier.evaluate(["a": .number(1), "b": .number(1)], config: c) == "high")
        #expect(GameDeviceTier.evaluate(["a": .number(1), "b": .number(0)], config: c) == "mid")
        #expect(GameDeviceTier.evaluate(["a": .number(0), "b": .number(0)], config: c) == "low")
    }

    @Test("the first matching rule wins")
    func firstWins() {
        let c = config(rules: #"[{"tier":"mid","all":[{"fact":"a","gte":1}]},{"tier":"high","all":[{"fact":"a","gte":2}]}]"#)
        #expect(GameDeviceTier.evaluate(["a": .number(5)], config: c) == "mid")
    }

    @Test("numeric operators compare at the boundary")
    func boundaries() {
        let c = config(rules: #"[{"tier":"high","all":[{"fact":"a","gt":2,"lte":4}]},{"tier":"mid","all":[{"fact":"a","lt":2}]}]"#)
        #expect(GameDeviceTier.evaluate(["a": .number(2)], config: c) == "low")
        #expect(GameDeviceTier.evaluate(["a": .number(4)], config: c) == "high")
        #expect(GameDeviceTier.evaluate(["a": .number(4.5)], config: c) == "low")
        #expect(GameDeviceTier.evaluate(["a": .number(1)], config: c) == "mid")
    }

    @Test("in matches any listed value")
    func inOperator() {
        let c = config(rules: #"[{"tier":"high","all":[{"fact":"os","in":["a","b"]}]}]"#)
        #expect(GameDeviceTier.evaluate(["os": .string("b")], config: c) == "high")
        #expect(GameDeviceTier.evaluate(["os": .string("c")], config: c) == "low")
    }

    @Test("a missing fact, a type mismatch or an unknown operator never matches")
    func neverMatches() {
        let c = config(rules: #"[{"tier":"high","any":[{"fact":"missing","eq":true},{"fact":"s","gte":1},{"fact":"a","near":1}]}]"#)
        #expect(GameDeviceTier.evaluate(["s": .string("1"), "a": .number(1)], config: c) == "low")
    }

    @Test("a JSON boolean is not the number 1")
    func boolIsNotNumber() {
        let c = config(rules: #"[{"tier":"high","all":[{"fact":"a","eq":true}]}]"#)
        #expect(GameDeviceTier.evaluate(["a": .number(1)], config: c) == "low")
        #expect(GameDeviceTier.evaluate(["a": .bool(true)], config: c) == "high")
    }

    // MARK: parse

    @Test("a valid config is used as sent")
    func valid() {
        let c = config(rules: #"[{"tier":"mid","all":[{"fact":"a","eq":1}]}]"#)
        #expect(c.rules.count == 1)
        #expect(c.rules.first?.tier == "mid")
        #expect(c.rules.first?.any == nil)
    }

    @Test("a malformed config falls back whole to the default")
    func malformed() {
        let bad = [
            #"{}"#,
            #"{"weights":{"cpuLevel":0},"rules":[],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":-1},"rules":[],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[],"fallback":"full"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[{"tier":"lite","all":[{"fact":"a","eq":1}]}],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[{"tier":"mid"}],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[]}],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[{"fact":"a"}]}],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[{"fact":"a","gte":"2"}]}],"fallback":"low"}"#,
            #"{"weights":{"cpuLevel":true},"rules":[],"fallback":"low"}"#,
        ]
        for text in bad {
            #expect(DeviceTierConfig.parse(json(text)) == .default, "\(text)")
        }
        #expect(DeviceTierConfig.parse(nil) == .default)
    }

    // MARK: levels

    @Test("memory pressure lowers the level by one, never below 1")
    func memoryLevel() {
        #expect(GameDeviceInfo.memoryLevel(totalMb: 12_288, availableMb: 6_000) == 4)
        #expect(GameDeviceInfo.memoryLevel(totalMb: 12_288, availableMb: 1_024) == 3)
        #expect(GameDeviceInfo.memoryLevel(totalMb: 2_048, availableMb: 100) == 1)
        #expect(GameDeviceInfo.memoryLevel(totalMb: 8_192, availableMb: nil) == 3)
        #expect(GameDeviceInfo.memoryLevel(totalMb: 8_192, availableMb: 0) == 3, "0 available is unknown, not pressure")
        #expect(GameDeviceInfo.memoryLevel(totalMb: 0, availableMb: nil) == 0)
    }

    @Test("charging lowers the battery thresholds")
    func batteryLevel() {
        #expect(GameDeviceInfo.batteryLevel(percentage: 75, charging: false) == 3)
        #expect(GameDeviceInfo.batteryLevel(percentage: 75, charging: true) == 4)
        #expect(GameDeviceInfo.batteryLevel(percentage: 37, charging: false) == 1)
        #expect(GameDeviceInfo.batteryLevel(percentage: 37, charging: true) == 2)
        #expect(GameDeviceInfo.batteryLevel(percentage: nil, charging: true) == 0)
    }

    @Test("thermal state maps nominal 4 down to critical 1")
    func thermalLevel() {
        #expect(GameDeviceInfo.thermalLevel(.nominal) == 4)
        #expect(GameDeviceInfo.thermalLevel(.fair) == 3)
        #expect(GameDeviceInfo.thermalLevel(.serious) == 2)
        #expect(GameDeviceInfo.thermalLevel(.critical) == 1)
    }

    @Test("cpu level follows cores and RAM, 0 when either is unknown")
    func cpuLevel() {
        #expect(GameDeviceInfo.cpuLevel(cores: 6, ramMb: 8_192) == 4)
        #expect(GameDeviceInfo.cpuLevel(cores: 6, ramMb: 4_096) == 3)
        #expect(GameDeviceInfo.cpuLevel(cores: 6, ramMb: 3_072) == 2)
        #expect(GameDeviceInfo.cpuLevel(cores: 2, ramMb: 8_192) == 1)
        #expect(GameDeviceInfo.cpuLevel(cores: 0, ramMb: 8_192) == 0)
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

    @Test("unknown sensors never start")
    func unknownSensorUnsupported() {
        let source = GameMotionSource()
        // Guards the name check in start: no hardware is touched.
        #expect(!source.start(sensor: "lidar", hz: 30) { _ in })
    }

    @Test("subscribe-all validates every sensor before starting any")
    func startAllValidatesFirst() {
        // Availability is stubbed: gyroscope present, everything else missing.
        let source = GameMotionSource(isAvailable: { $0 == GameMotionSource.gyroscopeName })
        defer { source.stopAll() }
        var events: [GameMotionEvent] = []
        // Guards the gate in startAll: lidar is missing, so gyroscope must
        // never start even though it is listed first and available.
        #expect(!source.startAll(sensors: ["gyroscope", "lidar"], hz: 30) { events.append($0) })
        #expect(source.activeSensorNames.isEmpty)
        #expect(events.isEmpty)
    }

    @Test("subscribe-all starts every sensor when all are available")
    func startAllStartsAll() {
        let source = GameMotionSource(isAvailable: { _ in true })
        defer { source.stopAll() }
        // Guards the start loop in startAll: every listed sensor streams.
        #expect(source.startAll(sensors: ["gyroscope"], hz: 30) { _ in })
        #expect(source.activeSensorNames == ["gyroscope"])
    }
}
