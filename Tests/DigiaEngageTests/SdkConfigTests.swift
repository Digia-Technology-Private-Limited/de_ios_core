import Foundation
import Testing

@testable import DigiaEngage

private func object(_ json: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

@Suite("SdkConfig resolve")
struct SdkConfigResolveTests {

    @Test("shipped defaults are health on, 20 per session")
    func shippedDefaults() {
        #expect(SdkConfig.defaults.healthEnabled == true)
        #expect(SdkConfig.defaults.healthSessionCap == 20)
    }

    @Test("nothing fetched or cached resolves to the defaults")
    func nothingResolvesToDefaults() {
        #expect(SdkConfig.resolve() == SdkConfig.defaults)
    }

    @Test("the switch is off only for an explicit false")
    func switchOffOnlyForFalse() {
        func enabled(_ health: String) -> Bool {
            SdkConfig.resolve(fetched: object(#"{"sdkHealth":\#(health)}"#)).healthEnabled
        }
        #expect(enabled(#"{"enabled":false}"#) == false)
        for on in [#"{"enabled":true}"#, "{}", #"{"enabled":null}"#, #"{"enabled":"false"}"#,
                   #"{"enabled":0}"#, #"{"enabled":1}"#, #"{"enabled":"off"}"#, "[]", #""off""#, "null"] {
            #expect(enabled(on), "\(on) must leave the switch on")
        }
    }

    @Test("a fetched response decides the switch, not the cache behind it")
    func fetchedDecidesSwitch() {
        let cachedOff = object(#"{"sdkHealth":{"enabled":false}}"#)
        #expect(SdkConfig.resolve(fetched: object("{}"), cached: cachedOff).healthEnabled == true)
        #expect(SdkConfig.resolve(cached: cachedOff).healthEnabled == false)
    }

    @Test("the session cap falls back fetched, then cached, then the default")
    func capFallbackChain() {
        let cached = object(#"{"sdkHealth":{"sessionCap":7}}"#)
        func cap(_ fetchedCap: String) -> Int {
            SdkConfig.resolve(fetched: object(#"{"sdkHealth":{"sessionCap":\#(fetchedCap)}}"#), cached: cached)
                .healthSessionCap
        }
        #expect(cap("3") == 3)
        #expect(cap("0") == 0)
        for bad in ["-1", "2.5", #""5""#, "true", "null", "[]"] {
            #expect(cap(bad) == 7, "\(bad) must fall through to the cache")
        }
        #expect(SdkConfig.resolve(fetched: object("{}")).healthSessionCap == HealthSink.defaultSessionCap)
        #expect(SdkConfig.resolve().healthSessionCap == HealthSink.defaultSessionCap)
    }

    @Test("a malformed field costs only itself")
    func fieldsAreIndependent() {
        let resolved = SdkConfig.resolve(
            fetched: object(#"{"sdkHealth":{"enabled":false,"sessionCap":"many"}}"#),
            cached: object(#"{"sdkHealth":{"sessionCap":7}}"#))
        #expect(resolved.healthEnabled == false)
        #expect(resolved.healthSessionCap == 7)
    }
}

@Suite("SdkConfig media caps")
struct SdkConfigMediaCapsTests {
    private static let mib = 1024 * 1024

    @Test("nothing fetched or cached resolves to 100 MiB each")
    func defaultsTo100MiB() {
        #expect(SdkConfig.defaults.imageDiskCacheBytes == 100 * Self.mib)
        #expect(SdkConfig.defaults.lottieDiskCacheBytes == 100 * Self.mib)
        #expect(SdkConfig.resolve().imageDiskCacheBytes == 100 * Self.mib)
        #expect(SdkConfig.resolve().lottieDiskCacheBytes == 100 * Self.mib)
    }

    @Test("a fetched media section is honored")
    func fetchedOverride() {
        let resolved = SdkConfig.resolve(
            fetched: object(#"{"media":{"imageDiskCacheBytes":67108864,"lottieDiskCacheBytes":33554432}}"#))
        #expect(resolved.imageDiskCacheBytes == 64 * Self.mib)
        #expect(resolved.lottieDiskCacheBytes == 32 * Self.mib)
    }

    @Test("the caps fall back fetched, then cached, then the default, one field at a time")
    func fallbackChain() {
        let cached = object(#"{"media":{"imageDiskCacheBytes":67108864,"lottieDiskCacheBytes":33554432}}"#)
        let fetched = SdkConfig.resolve(
            fetched: object(#"{"media":{"imageDiskCacheBytes":50331648}}"#), cached: cached)
        #expect(fetched.imageDiskCacheBytes == 48 * Self.mib)
        #expect(fetched.lottieDiskCacheBytes == 32 * Self.mib)

        let fromCache = SdkConfig.resolve(fetched: object("{}"), cached: cached)
        #expect(fromCache.imageDiskCacheBytes == 64 * Self.mib)
        #expect(fromCache.lottieDiskCacheBytes == 32 * Self.mib)
    }

    @Test("a non-positive or malformed cap costs only itself, a small positive cap is honored")
    func badValuesAreIsolated() {
        let cached = object(#"{"media":{"imageDiskCacheBytes":67108864,"lottieDiskCacheBytes":33554432}}"#)
        // Zero, negative, fractional, wrong-typed and boolean values are ignored, per field.
        for bad in ["0", "-1", "8388607.5", #""67108864""#, "true", "null", "[]"] {
            let resolved = SdkConfig.resolve(
                fetched: object(#"{"media":{"imageDiskCacheBytes":\#(bad),"lottieDiskCacheBytes":20971520}}"#),
                cached: cached)
            #expect(resolved.imageDiskCacheBytes == 64 * Self.mib, "\(bad) must fall through to the cache")
            // The sibling field still reads the fetched value: one bad field costs only itself.
            #expect(resolved.lottieDiskCacheBytes == 20 * Self.mib)
        }
        // A small positive cap is a cap like any other: there is no minimum.
        let small = SdkConfig.resolve(fetched: object(#"{"media":{"imageDiskCacheBytes":1048576}}"#))
        #expect(small.imageDiskCacheBytes == 1 * Self.mib)
        // Nothing usable anywhere resolves to the default.
        let resolved = SdkConfig.resolve(fetched: object(#"{"media":{"imageDiskCacheBytes":"many"}}"#))
        #expect(resolved.imageDiskCacheBytes == 100 * Self.mib)
        #expect(resolved.lottieDiskCacheBytes == 100 * Self.mib)
    }

    @Test("the caps are part of equality")
    func capsParticipateInEquality() {
        let base = SdkConfig(healthEnabled: true, healthSessionCap: 20)
        #expect(base == SdkConfig(healthEnabled: true, healthSessionCap: 20))
        #expect(base != SdkConfig(healthEnabled: true, healthSessionCap: 20, imageDiskCacheBytes: 64 * Self.mib))
        #expect(base != SdkConfig(healthEnabled: true, healthSessionCap: 20, lottieDiskCacheBytes: 32 * Self.mib))
    }

    @Test("a bad media section leaves the other sections alone")
    func mediaIndependentOfOtherSections() {
        let resolved = SdkConfig.resolve(fetched: object(
            #"{"sdkHealth":{"enabled":false},"media":{"imageDiskCacheBytes":"many"}}"#))
        #expect(resolved.healthEnabled == false)
        #expect(resolved.imageDiskCacheBytes == 100 * Self.mib)
    }
}

@Suite("SdkConfig app events")
struct SdkConfigAppEventsTests {
    @Test("app-event controls and limits are read, a limit below 1 is ignored, fields fall back one by one")
    func appEventsSection() {
        let fetched = object(
            #"""
            {"appEvents":{"upload":false,"ratePerMinute":30,"burst":5,"blockedNames":["a",7,"b"],
             "limits":{"maxProperties":3,"nameMaxLength":0,"propertyKeyMaxLength":"x"}}}
            """#)
        let cached = object(#"{"appEvents":{"limits":{"propertyKeyMaxLength":40,"listMaxItems":9}}}"#)
        let policy = SdkConfig.resolve(fetched: fetched, cached: cached).appEvents
        #expect(policy.enabled == false)
        #expect(policy.ratePerMinute == 30)
        #expect(policy.burst == 5)
        #expect(policy.blockedNames == ["a", "b"])
        #expect(policy.limits.maxProperties == 3)
        #expect(policy.limits.nameMaxLength == appEventNameMaxLength)
        #expect(policy.limits.propertyKeyMaxLength == 40)
        #expect(policy.limits.listMaxItems == 9)
        #expect(policy.limits.stringMaxLength == appEventPropertyStringMaxLength)
    }

    @Test("the upload switch is off only for an explicit false")
    func uploadOffOnlyForFalse() {
        #expect(SdkConfig.resolve(fetched: object(#"{"appEvents":{"upload":"no"}}"#)).appEvents.enabled)
        #expect(SdkConfig.resolve(fetched: object(#"{"appEvents":{"upload":0}}"#)).appEvents.enabled)
        #expect(SdkConfig.resolve().appEvents == .unlimited)
    }
}

@Suite("SdkConfig game prewarm")
struct SdkConfigGamePrewarmTests {
    @Test("game prewarm is opt-in: on only for explicit true, eligible only for a listed tier")
    func gamePrewarmOptIn() {
        #expect(SdkConfig.resolve().gamePrewarm == .off)
        #expect(SdkConfig.defaults.gamePrewarm == .off)
        let mistyped = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"prewarm":{"engine":1,"game":true}}}"#)).gamePrewarm
        #expect(mistyped.engine == false)
        #expect(mistyped.game == true)
        #expect(mistyped.tiers == ["high"], "tiers default to high")

        let on = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"prewarm":{"engine":true}}}"#)).gamePrewarm
        #expect(on.allowsEngine(tier: "high"))
        #expect(on.allowsEngine(tier: "mid") == false)
        #expect(on.allowsGame(tier: "high") == false, "game defaults off")

        let all = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"prewarm":{"engine":true,"tiers":["high","mid","low"]}}}"#)).gamePrewarm
        #expect(all.allowsEngine(tier: "low"))
        let unknown = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"prewarm":{"engine":true,"tiers":["high","full"]}}}"#)).gamePrewarm
        #expect(unknown.tiers == ["high"], "one unknown tier falls back whole")
    }

    @Test("deviceTier parses a valid config and falls back to the default on a bad one")
    func deviceTierParse() {
        #expect(SdkConfig.resolve().deviceTier == .default)
        let valid = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"deviceTier":{"weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[{"fact":"a","eq":1}]}],"fallback":"low"}}}"#)).deviceTier
        #expect(valid.rules.count == 1)
        #expect(valid.rules.first?.tier == "mid")
        let bad = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"deviceTier":{"weights":{"cpuLevel":1},"rules":[],"fallback":"full"}}}"#)).deviceTier
        #expect(bad == .default)
    }
}

@Suite("SdkConfig game limits")
struct SdkConfigGameLimitsTests {
    private func limits(_ json: String) -> GameSkinLimits {
        SdkConfig.resolve(fetched: object(json)).gameSkinLimits
    }

    private func storage(_ json: String) -> GameStorageLimits {
        SdkConfig.resolve(fetched: object(json)).gameStorageLimits
    }

    @Test("limits and storage default to the burned caps")
    func shippedDefaults() {
        #expect(SdkConfig.resolve().gameSkinLimits == .defaults)
        #expect(SdkConfig.resolve().gameStorageLimits == .defaults)
        #expect(GameSkinLimits.defaults.skinFileMaxBytes == 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10)
        #expect(GameSkinLimits.defaults.skinCacheMaxBytes == 16 * 1024 * 1024)
        #expect(GameSkinLimits.defaults.bridgeMessageMaxBytes == 64 * 1024)
        #expect(GameStorageLimits.defaults.valueMaxBytes == 16 * 1024)
        #expect(GameStorageLimits.defaults.namespaceMaxBytes == 64 * 1024)
    }

    @Test("a full section is read as sent")
    func fullSectionRead() {
        let skin = limits(
            #"{"gamification":{"limits":{"skinFileMaxBytes":2097152,"skinCacheMaxBytes":33554432,"bridgeMessageMaxBytes":32768}}}"#)
        #expect(skin == GameSkinLimits(
            skinFileMaxBytes: 2 * 1024 * 1024, skinCacheMaxBytes: 32 * 1024 * 1024,
            bridgeMessageMaxBytes: 32 * 1024))
        let quotas = storage(
            #"{"gamification":{"storage":{"valueMaxBytes":8192,"namespaceMaxBytes":32768}}}"#)
        #expect(quotas == GameStorageLimits(valueMaxBytes: 8 * 1024, namespaceMaxBytes: 32 * 1024))
    }

    @Test("absent keys take their defaults")
    func absentKeysDefault() {
        let skin = limits(#"{"gamification":{"limits":{"skinFileMaxBytes":2097152}}}"#)
        #expect(skin.skinFileMaxBytes == 2 * 1024 * 1024)
        #expect(skin.skinCacheMaxBytes == GameSkinLimits.defaults.skinCacheMaxBytes)
        #expect(skin.bridgeMessageMaxBytes == GameSkinLimits.defaults.bridgeMessageMaxBytes)
    }

    @Test("an out-of-range value falls its whole section back to the defaults")
    func outOfRangeFallsWholeSectionBack() {
        // Guards the range check in rangedBytes: one value outside the
        // backend's ranges fails its whole section, like Android's
        // `game caps outside their native range are ignored`.
        for section in [
            #"{"gamification":{"limits":{"skinFileMaxBytes":0}}}"#,
            #"{"gamification":{"limits":{"skinFileMaxBytes":20971521}}}"#,
            #"{"gamification":{"limits":{"skinCacheMaxBytes":1024}}}"#,
            #"{"gamification":{"limits":{"skinCacheMaxBytes":2147483648}}}"#,
            #"{"gamification":{"limits":{"bridgeMessageMaxBytes":100}}}"#,
            #"{"gamification":{"limits":{"bridgeMessageMaxBytes":9999999}}}"#,
            #"{"gamification":{"storage":{"valueMaxBytes":100}}}"#,
            #"{"gamification":{"storage":{"valueMaxBytes":9999999}}}"#,
            #"{"gamification":{"storage":{"namespaceMaxBytes":100}}}"#,
            #"{"gamification":{"storage":{"namespaceMaxBytes":99999999}}}"#,
        ] {
            #expect(limits(section) == .defaults, "\(section)")
            #expect(storage(section) == .defaults, "\(section)")
        }
        // A value past Int range still fails whole instead of trapping: the
        // range check runs on the double before converting.
        let huge = limits(#"{"gamification":{"limits":{"skinFileMaxBytes":1e30}}}"#)
        #expect(huge == .defaults)
    }

    @Test("values at the backend range edges are kept")
    func rangeEdgesKept() {
        // Guards the exact backend ranges: file 1 byte…20 MB, cache
        // 1 MB…1 GB, message 1 KB…1 MB, value 1 KB…1 MB, namespace 4 KB…16 MB.
        let low = limits(
            #"{"gamification":{"limits":{"skinFileMaxBytes":1,"skinCacheMaxBytes":1048576,"bridgeMessageMaxBytes":1024}}}"#)
        #expect(low.skinFileMaxBytes == 1)
        #expect(low.skinCacheMaxBytes == 1 * 1024 * 1024)
        #expect(low.bridgeMessageMaxBytes == 1024)
        let high = limits(
            #"{"gamification":{"limits":{"skinFileMaxBytes":20971520,"skinCacheMaxBytes":1073741824,"bridgeMessageMaxBytes":1048576}}}"#)
        #expect(high.skinFileMaxBytes == 20 * 1024 * 1024)
        #expect(high.skinCacheMaxBytes == 1024 * 1024 * 1024)
        #expect(high.bridgeMessageMaxBytes == 1024 * 1024)
        let quotasLow = storage(
            #"{"gamification":{"storage":{"valueMaxBytes":1024,"namespaceMaxBytes":4096}}}"#)
        #expect(quotasLow.valueMaxBytes == 1024)
        #expect(quotasLow.namespaceMaxBytes == 4 * 1024)
        let quotasHigh = storage(
            #"{"gamification":{"storage":{"valueMaxBytes":1048576,"namespaceMaxBytes":16777216}}}"#)
        #expect(quotasHigh.valueMaxBytes == 1024 * 1024)
        #expect(quotasHigh.namespaceMaxBytes == 16 * 1024 * 1024)
    }

    @Test("a non-numeric value falls the whole section back to the defaults")
    func nonNumericFallsWholeSectionBack() {
        for section in [
            #"{"gamification":{"limits":{"skinFileMaxBytes":"big","skinCacheMaxBytes":33554432,"bridgeMessageMaxBytes":32768}}}"#,
            #"{"gamification":{"limits":{"skinFileMaxBytes":true}}}"#,
            #"{"gamification":{"limits":{"skinFileMaxBytes":2097152.5}}}"#,
            #"{"gamification":{"limits":{"bridgeMessageMaxBytes":[1]}}}"#,
            #"{"gamification":{"limits":{"skinCacheMaxBytes":null}}}"#,
        ] {
            #expect(limits(section) == .defaults, "\(section)")
        }
        for section in [
            #"{"gamification":{"storage":{"valueMaxBytes":"big","namespaceMaxBytes":32768}}}"#,
            #"{"gamification":{"storage":{"valueMaxBytes":false}}}"#,
        ] {
            #expect(storage(section) == .defaults, "\(section)")
        }
    }

    @Test("a malformed section costs only itself, not its neighbour")
    func malformedCostsOnlyItself() {
        let resolved = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"limits":{"skinFileMaxBytes":"big"},"storage":{"valueMaxBytes":8192}}}"#))
        #expect(resolved.gameSkinLimits == .defaults)
        #expect(resolved.gameStorageLimits == GameStorageLimits(
            valueMaxBytes: 8 * 1024, namespaceMaxBytes: GameStorageLimits.defaults.namespaceMaxBytes))
        let flipped = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"limits":{"skinFileMaxBytes":2097152},"storage":{"valueMaxBytes":"big"}}}"#))
        #expect(flipped.gameSkinLimits.skinFileMaxBytes == 2 * 1024 * 1024)
        #expect(flipped.gameStorageLimits == .defaults)
    }

    @Test("one out-of-range value fails its whole section, not its neighbour")
    func mixedPayloadOutOfRangeFallsWholeSectionBack() {
        // Guards the whole-section rule in parse: a valid file cap beside
        // an out-of-range cache cap still falls the whole limits section
        // back — the valid key does not survive — while storage parses alone.
        let resolved = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"limits":{"skinFileMaxBytes":2097152,"skinCacheMaxBytes":9999999999},"storage":{"valueMaxBytes":8192}}}"#))
        #expect(resolved.gameSkinLimits == .defaults)
        #expect(resolved.gameStorageLimits == GameStorageLimits(
            valueMaxBytes: 8 * 1024, namespaceMaxBytes: GameStorageLimits.defaults.namespaceMaxBytes))
        // Mirrored: a valid storage quota beside an out-of-range namespace
        // quota fails the whole storage section; limits parse alone.
        let flipped = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"limits":{"bridgeMessageMaxBytes":32768},"storage":{"valueMaxBytes":8192,"namespaceMaxBytes":1}}}"#))
        #expect(flipped.gameSkinLimits == GameSkinLimits(
            skinFileMaxBytes: GameSkinLimits.defaults.skinFileMaxBytes,
            skinCacheMaxBytes: GameSkinLimits.defaults.skinCacheMaxBytes,
            bridgeMessageMaxBytes: 32 * 1024))
        #expect(flipped.gameStorageLimits == .defaults)
    }

    @Test("the fetched section wins whole over the cached one")
    func fetchedWinsWholeOverCached() {
        let cached = object(#"{"gamification":{"limits":{"skinFileMaxBytes":2097152}}}"#)
        let fetched = object(#"{"gamification":{"limits":{"bridgeMessageMaxBytes":32768}}}"#)
        let resolved = SdkConfig.resolve(fetched: fetched, cached: cached).gameSkinLimits
        // Guards the whole-fallback rule: the fetched section decides alone, so the
        // cached file cap does not leak in beside the fetched message cap.
        #expect(resolved == GameSkinLimits(
            skinFileMaxBytes: GameSkinLimits.defaults.skinFileMaxBytes,
            skinCacheMaxBytes: GameSkinLimits.defaults.skinCacheMaxBytes,
            bridgeMessageMaxBytes: 32 * 1024))
        #expect(SdkConfig.resolve(cached: cached).gameSkinLimits.skinFileMaxBytes == 2 * 1024 * 1024)
    }
}

@Suite("SdkConfig game thresholds")
struct SdkConfigGameMeasurementTests {
    private func measurement(_ json: String) -> GameMeasurementThresholds {
        SdkConfig.resolve(fetched: object(json)).gameMeasurement
    }

    /// The cross-stack parity vector: every field off-default but in range.
    /// Android resolves the same input to the same thresholds.
    private static let parityJson = #"{"gamification":{"deviceTier":{"thresholds":{"ramLowGb":3.0,"ramMidGb":7.0,"ramHighGb":11.0,"heapLowMb":100,"heapMidMb":180,"heapHighMb":300,"heapPressureRatio":0.8,"availThresholdFactor":2.0,"batteryHigh":85,"batteryHighCharging":75,"batteryMid":60,"batteryMidCharging":55,"batteryLow":45,"batteryLowCharging":40,"cpuScoreLow":25,"cpuScoreMid":40,"cpuScoreHigh":60,"cpuCapRamLowGb":3.0,"cpuCapRamMidGb":4.0,"cpuCapHeapLow":110,"cpuCapHeapMid":170,"lowRamDeviceMb":2048}}}}"#
    private static let parity = GameMeasurementThresholds(
        ramLowGb: 3.0, ramMidGb: 7.0, ramHighGb: 11.0,
        heapLowMb: 100, heapMidMb: 180, heapHighMb: 300,
        heapPressureRatio: 0.8, availThresholdFactor: 2.0,
        batteryHigh: 85, batteryHighCharging: 75,
        batteryMid: 60, batteryMidCharging: 55,
        batteryLow: 45, batteryLowCharging: 40,
        cpuScoreLow: 25, cpuScoreMid: 40, cpuScoreHigh: 60,
        cpuCapRamLowGb: 3.0, cpuCapRamMidGb: 4.0,
        cpuCapHeapLow: 110, cpuCapHeapMid: 170,
        lowRamDeviceMb: 2048
    )

    @Test("absent resolves to today's hardcoded cutoffs with no low-RAM override")
    func defaultsAreToday() {
        // Guards the defaults table and the resolve wiring: the shipped
        // numbers are the ones the level math hardcoded before.
        #expect(SdkConfig.resolve().gameMeasurement == .defaults)
        let d = GameMeasurementThresholds.defaults
        #expect(d.ramLowGb == 2.8)
        #expect(d.ramMidGb == 6.9)
        #expect(d.ramHighGb == 10.5)
        #expect(d.heapLowMb == 128)
        #expect(d.heapMidMb == 160)
        #expect(d.heapHighMb == 256)
        #expect(d.heapPressureRatio == 0.75)
        #expect(d.availThresholdFactor == 1.5)
        #expect(d.batteryHigh == 80)
        #expect(d.batteryHighCharging == 70)
        #expect(d.batteryMid == 55)
        #expect(d.batteryMidCharging == 50)
        #expect(d.batteryLow == 40)
        #expect(d.batteryLowCharging == 35)
        #expect(d.cpuScoreLow == 20)
        #expect(d.cpuScoreMid == 34)
        #expect(d.cpuScoreHigh == 56)
        #expect(d.cpuCapRamLowGb == 2.8)
        #expect(d.cpuCapRamMidGb == 3.6)
        #expect(d.cpuCapHeapLow == 100)
        #expect(d.cpuCapHeapMid == 160)
        #expect(d.lowRamDeviceMb == nil)
    }

    @Test("a full section reads as sent")
    func fullSectionRead() {
        // Guards every parse binding: one line per field, all must hold.
        #expect(measurement(Self.parityJson) == Self.parity)
    }

    @Test("absent keys take their defaults")
    func absentKeysDefault() {
        // Guards the per-key fallback: only the sent keys move.
        let m = measurement(#"{"gamification":{"deviceTier":{"thresholds":{"ramLowGb":3.0,"batteryHigh":85}}}}"#)
        #expect(m.ramLowGb == 3.0)
        #expect(m.batteryHigh == 85)
        #expect(m.ramMidGb == GameMeasurementThresholds.defaults.ramMidGb)
        #expect(m.batteryMid == GameMeasurementThresholds.defaults.batteryMid)
        #expect(m.lowRamDeviceMb == nil)
    }

    @Test("a malformed or out-of-range value falls the whole section back")
    func malformedFallsWholeSectionBack() {
        // Guards the whole-fallback rule: one bad value costs the section,
        // even beside valid ones. The base holds keys no bad entry touches,
        // so each payload has one value per key.
        let base = #"{"gamification":{"deviceTier":{"thresholds":{"heapMidMb":180,"cpuCapRamLowGb":3.0"#
        for bad in [
            #","ramMidGb":"much"}}}}"#, // string
            #","ramMidGb":true}}}}"#, // boolean
            #","heapLowMb":128.5}}}}"#, // fractional Mb
            #","ramLowGb":0.4}}}}"#, // Gb below range
            #","ramHighGb":33}}}}"#, // Gb above range
            #","heapHighMb":1025}}}}"#, // Mb above range
            #","heapPressureRatio":5.1}}}}"#, // ratio above range
            #","availThresholdFactor":-0.1}}}}"#, // ratio below range
            #","batteryHigh":101}}}}"#, // battery above range
            #","batteryLowCharging":-1}}}}"#, // battery below range
            #","cpuScoreLow":0.9}}}}"#, // score below range
            #","cpuScoreHigh":201}}}}"#, // score above range
            #","cpuCapHeapLow":15}}}}"#, // heap cap below range
            #","lowRamDeviceMb":100}}}}"#, // hatch below 512
            #","lowRamDeviceMb":256}}}}"#, // hatch below 512
            #","lowRamDeviceMb":511}}}}"#, // hatch below 512
            #","lowRamDeviceMb":512.5}}}}"#, // hatch must be whole
            #","lowRamDeviceMb":8193}}}}"#, // hatch above 8192
            #","lowRamDeviceMb":32768}}}}"#, // hatch above 8192
            #","lowRamDeviceMb":40000}}}}"#, // hatch above range
            #","lowRamDeviceMb":"2048"}}}}"#, // a numeric string is still malformed
            #","batteryHigh":null}}}}"#, // explicit null is malformed
        ] {
            #expect(measurement(base + bad) == .defaults, "\(bad)")
        }
    }

    @Test("blank lowRamDeviceMb is unset, a set value wins")
    func blankLowRamIsUnset() {
        // Guards the lowRam tri-state: absent, null and blank stay missing.
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"ramLowGb":3.0}}}}"#).lowRamDeviceMb == nil)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":null}}}}"#).lowRamDeviceMb == nil)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":""}}}}"#).lowRamDeviceMb == nil)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":"   "}}}}"#).lowRamDeviceMb == nil)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":2048}}}}"#).lowRamDeviceMb == 2048)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":512}}}}"#).lowRamDeviceMb == 512)
        #expect(measurement(#"{"gamification":{"deviceTier":{"thresholds":{"lowRamDeviceMb":8192}}}}"#).lowRamDeviceMb == 8192)
    }

    @Test("the fetched section wins whole over the cached one")
    func fetchedWinsWholeOverCached() {
        let cached = object(#"{"gamification":{"deviceTier":{"thresholds":{"ramLowGb":3.0,"batteryHigh":85}}}}"#)
        let fetched = object(#"{"gamification":{"deviceTier":{"thresholds":{"batteryMid":60}}}}"#)
        let resolved = SdkConfig.resolve(fetched: fetched, cached: cached).gameMeasurement
        // Guards the whole-section rule: the fetched section decides alone,
        // so the cached cutoffs don't leak in beside the fetched one.
        #expect(resolved.ramLowGb == GameMeasurementThresholds.defaults.ramLowGb)
        #expect(resolved.batteryHigh == GameMeasurementThresholds.defaults.batteryHigh)
        #expect(resolved.batteryMid == 60)
        #expect(SdkConfig.resolve(cached: cached).gameMeasurement.ramLowGb == 3.0)
    }

    @Test("a malformed section costs only itself, not its neighbour")
    func malformedCostsOnlyItself() {
        // Same input as Android's mixed thresholds payload: same resolved values.
        let resolved = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"limits":{"skinFileMaxBytes":4194304},"deviceTier":{"thresholds":{"ramLowGb":3.0,"heapLowMb":"huge"}},"storage":{"valueMaxBytes":8192}}}"#))
        #expect(resolved.gameMeasurement == .defaults)
        #expect(resolved.gameSkinLimits.skinFileMaxBytes == 4194304)
        #expect(resolved.gameStorageLimits.valueMaxBytes == 8192)
    }

    @Test("bad thresholds never nuke rules and bad rules never nuke thresholds")
    func thresholdsIndependentOfRules() {
        let goodRules = #""weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[{"fact":"a","gte":1}]}],"fallback":"low""#
        let resolvedBadThresholds = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"deviceTier":{\#(goodRules),"thresholds":{"ramLowGb":"huge"}}}}"#))
        #expect(resolvedBadThresholds.deviceTier.rules.first?.tier == "mid")
        #expect(resolvedBadThresholds.gameMeasurement == .defaults)
        let resolvedBadRules = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"deviceTier":{"weights":{"cpuLevel":-1},"rules":[],"fallback":"low","thresholds":{"ramLowGb":3.0,"lowRamDeviceMb":1024}}}}"#))
        #expect(resolvedBadRules.deviceTier == .default)
        #expect(resolvedBadRules.gameMeasurement.ramLowGb == 3.0)
        #expect(resolvedBadRules.gameMeasurement.lowRamDeviceMb == 1024)
    }

    @Test("a mixed deviceTier payload resolves rules and thresholds together")
    func mixedDeviceTierPayload() {
        // Same input as Android: rules and thresholds land together.
        let resolved = SdkConfig.resolve(fetched: object(
            #"{"gamification":{"deviceTier":{"weights":{"cpuLevel":1},"rules":[{"tier":"mid","all":[{"fact":"a","gte":1}]}],"fallback":"mid","thresholds":{"ramLowGb":3.0,"heapLowMb":130,"batteryHigh":90,"cpuScoreLow":25,"cpuCapRamLowGb":3.0,"lowRamDeviceMb":1024}},"limits":{"skinFileMaxBytes":4194304},"storage":{"valueMaxBytes":8192}}}"#))
        #expect(resolved.deviceTier.fallback == "mid")
        #expect(resolved.deviceTier.rules.first?.tier == "mid")
        #expect(resolved.gameMeasurement.ramLowGb == 3.0)
        #expect(resolved.gameMeasurement.lowRamDeviceMb == 1024)
        #expect(resolved.gameSkinLimits.skinFileMaxBytes == 4194304)
        #expect(resolved.gameStorageLimits.valueMaxBytes == 8192)
    }
}

@MainActor
@Suite("SdkConfigStore")
struct SdkConfigStoreTests {

    private func storage() -> LocalStorage {
        UserDefaultsLocalStorage(defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!)
    }

    private func respond(_ client: MockNetworkClient, status: Int, body: String) {
        client.enqueueResponse(url: DigiaEndpoints.sdkConfig, statusCode: status, body: body)
    }

    @Test("a good response is saved and read back by the next launch")
    func fetchPersists() async {
        let storage = storage()
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"sdkHealth":{"enabled":false,"sessionCap":4}}"#)

        let first = SdkConfigStore(storage: storage, projectKey: "k")
        #expect(first.cached == nil)
        let fetched = await first.fetch(using: client)

        #expect(fetched == SdkConfig(healthEnabled: false, healthSessionCap: 4))
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == fetched)
    }

    @Test("the call posts an empty body to getSdkConfig")
    func postsEmptyBody() async {
        let client = MockNetworkClient()
        respond(client, status: 200, body: "{}")
        _ = await SdkConfigStore(storage: storage(), projectKey: "k").fetch(using: client)

        let request = client.recordedRequests.first { $0.url.absoluteString.hasSuffix("/getSdkConfig") }
        #expect(request?.method == .post)
        #expect(request?.body.flatMap { String(data: $0, encoding: .utf8) } == "{}")
    }

    @Test("the response envelope is unwrapped")
    func envelopeUnwrapped() async {
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"data":{"response":{"sdkHealth":{"sessionCap":9}}}}"#)
        #expect(await SdkConfigStore(storage: storage(), projectKey: "k").fetch(using: client)?.healthSessionCap == 9)

        respond(client, status: 200, body: #"{"response":{"sdkHealth":{"sessionCap":11}}}"#)
        #expect(await SdkConfigStore(storage: storage(), projectKey: "k").fetch(using: client)?.healthSessionCap == 11)
    }

    @Test("an envelope without a response is not a config and is not saved")
    func envelopeWithoutResponseIgnored() async {
        let storage = storage()
        let seed = MockNetworkClient()
        respond(seed, status: 200, body: #"{"sdkHealth":{"sessionCap":4}}"#)
        _ = await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: seed)
        let saved = SdkConfigStore(storage: storage, projectKey: "k").cached

        for body in [#"{"data":{"error":"unauthorized"}}"#, #"{"error":"unauthorized"}"#,
                    #"{"data":{"response":"x"}}"#, #"{"response":"x"}"#] {
            let client = MockNetworkClient()
            respond(client, status: 200, body: body)
            #expect(await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: client) == nil)
            #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)
        }
    }

    @Test("an unreadable cache counts as no cache")
    func unreadableCacheIsNoCache() {
        let storage = storage()
        storage.set("{not json", forKey: "k")
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == nil)

        storage.set("[1,2]", forKey: "k")
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == nil)
    }

    @Test("a cache belongs to its project key")
    func cacheIsPerProject() async {
        let storage = storage()
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"sdkHealth":{"enabled":false}}"#)
        _ = await SdkConfigStore(storage: storage, projectKey: "key-a").fetch(using: client)

        #expect(SdkConfigStore(storage: storage, projectKey: "key-a").cached != nil)
        #expect(SdkConfigStore(storage: storage, projectKey: "key-b").cached == nil)
    }

    @Test("a response is still applied when it cannot be saved")
    func saveFailureStillApplies() async {
        let backing = storage()
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"sdkHealth":{"enabled":false,"sessionCap":4}}"#)

        let fetched = await SdkConfigStore(storage: DropWritesStorage(backing), projectKey: "k")
            .fetch(using: client)
        #expect(fetched == SdkConfig(healthEnabled: false, healthSessionCap: 4))
    }

    @Test("a failed call returns null and leaves the cache as it was")
    func failureKeepsCache() async {
        let storage = storage()
        let seed = MockNetworkClient()
        respond(seed, status: 200, body: #"{"sdkHealth":{"enabled":false,"sessionCap":4}}"#)
        let saved = await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: seed)

        for (status, body) in [(500, #"{"sdkHealth":{"enabled":true}}"#), (200, "[]"), (200, "not json")] {
            let client = MockNetworkClient()
            respond(client, status: status, body: body)
            #expect(await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: client) == nil)
            #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)
        }

        let broken = MockNetworkClient()
        broken.simulateTransportError(URLError(.notConnectedToInternet))
        #expect(await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: broken) == nil)
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)

        let hanging = SdkConfigStore(storage: storage, projectKey: "k", timeout: 0.1)
        #expect(await hanging.fetch(using: SilentNetworkClient()) == nil)
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)
    }
}

/// Drops every write, as a full disk does. Reads go to the backing store.
private final class DropWritesStorage: LocalStorage, @unchecked Sendable {
    private let backing: LocalStorage
    init(_ backing: LocalStorage) { self.backing = backing }
    func string(forKey key: String) -> String? { backing.string(forKey: key) }
    func set(_ value: String?, forKey key: String) {}
    func bool(forKey key: String) -> Bool { backing.bool(forKey: key) }
    func set(_ value: Bool, forKey key: String) {}
    func integer(forKey key: String) -> Int { backing.integer(forKey: key) }
    func set(_ value: Int, forKey key: String) {}
    func double(forKey key: String) -> Double { backing.double(forKey: key) }
    func set(_ value: Double, forKey key: String) {}
    func data(forKey key: String) -> Data? { backing.data(forKey: key) }
    func set(_ value: Data?, forKey key: String) {}
    func removeObject(forKey key: String) {}
    func scoped(_ domain: String) -> LocalStorage { DropWritesStorage(backing.scoped(domain)) }
}

/// Never answers; the fetch gives up at its timeout.
private final class SilentNetworkClient: NetworkClient, @unchecked Sendable {
    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        throw URLError(.timedOut)
    }

    func executeCapped(request: NetworkRequest, maxBytes: Int) async throws -> NetworkResponse {
        let response = try await execute(request: request)
        guard let body = response.body, body.count > maxBytes else { return response }
        return NetworkResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: Data(body.prefix(maxBytes + 1)),
            isSuccessful: response.isSuccessful)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        throw URLError(.timedOut)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        MockNetworkClient().openSseStream(request: request, handler: handler)
    }
}
