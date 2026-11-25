import Foundation

private let log = DigiaLogger()

/// The flags and limits the backend can change without an SDK release.
/// `sdkHealth`, `appEvents`, `gamification.prewarm`, `gamification.deviceTier`,
/// `gamification.measurement`, `gamification.limits` and `gamification.storage`
/// are read here; the saved response is kept whole.
/// `gamification.limits`: caps for skin downloads, the skin cache and the
/// bridge intake. The ranges mirror the backend's `LIMIT_RANGES` in
/// `gamificationConfig.ts`, the source of truth. A present value must be a
/// finite whole number inside its range; absent keys take their default. A
/// malformed or out-of-range value falls the whole section back to the
/// defaults (like `deviceTier`), never half-applies, and never throws.
struct GameSkinLimits: Equatable, Sendable {
    /// One self-contained skin file. Default is the old whole-bundle budget
    /// (3 MB + 10%); valid 1 byte…20 MB.
    var skinFileMaxBytes: Int
    /// The whole skin cache across entries. Default 16 MB; valid 1 MB…1 GB.
    var skinCacheMaxBytes: Int
    /// One skin bridge message. Default 64 KB; valid 1 KB…1 MB.
    var bridgeMessageMaxBytes: Int

    static let minSkinFileBytes = 1
    static let maxSkinFileBytes = 20 * 1024 * 1024
    static let minSkinCacheBytes = 1 * 1024 * 1024
    static let maxSkinCacheBytes = 1024 * 1024 * 1024
    static let minBridgeMessageBytes = 1 * 1024
    static let maxBridgeMessageBytes = 1024 * 1024

    static let defaults = GameSkinLimits(
        skinFileMaxBytes: 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10,
        skinCacheMaxBytes: 16 * 1024 * 1024,
        bridgeMessageMaxBytes: 64 * 1024
    )

    static func parse(_ json: [String: Any]?) -> GameSkinLimits {
        guard let json else { return .defaults }
        guard let file = rangedBytes(
            json["skinFileMaxBytes"], default: defaults.skinFileMaxBytes,
            min: minSkinFileBytes, max: maxSkinFileBytes),
            let cache = rangedBytes(
                json["skinCacheMaxBytes"], default: defaults.skinCacheMaxBytes,
                min: minSkinCacheBytes, max: maxSkinCacheBytes),
            let message = rangedBytes(
                json["bridgeMessageMaxBytes"], default: defaults.bridgeMessageMaxBytes,
                min: minBridgeMessageBytes, max: maxBridgeMessageBytes)
        else { return .defaults }
        return GameSkinLimits(
            skinFileMaxBytes: file, skinCacheMaxBytes: cache, bridgeMessageMaxBytes: message)
    }

    /// Absent reads as the default; a present value must be a finite whole
    /// number inside `[min, max]` — the backend's typo guards. Anything else
    /// is nil, failing the whole section. The range check runs on the double
    /// before converting, so a huge value fails instead of trapping `Int`.
    static func rangedBytes(_ raw: Any?, default fallback: Int, min: Int, max: Int) -> Int? {
        guard let raw else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == floor(value),
              value >= Double(min), value <= Double(max)
        else { return nil }
        return Int(value)
    }
}

/// `gamification.storage`: the per-skin key-value quotas. Same whole-fallback
/// rule as `limits`: absent keys take their default, a malformed or
/// out-of-range value falls the whole section back to the defaults.
struct GameStorageLimits: Equatable, Sendable {
    /// One storage value. Default 16 KB; valid 1 KB…1 MB.
    var valueMaxBytes: Int
    /// One skin namespace across keys. Default 64 KB; valid 4 KB…16 MB.
    var namespaceMaxBytes: Int

    static let minValueBytes = 1 * 1024
    static let maxValueBytes = 1024 * 1024
    static let minNamespaceBytes = 4 * 1024
    static let maxNamespaceBytes = 16 * 1024 * 1024

    static let defaults = GameStorageLimits(valueMaxBytes: 16 * 1024, namespaceMaxBytes: 64 * 1024)

    static func parse(_ json: [String: Any]?) -> GameStorageLimits {
        guard let json else { return .defaults }
        guard let value = GameSkinLimits.rangedBytes(
            json["valueMaxBytes"], default: defaults.valueMaxBytes,
            min: minValueBytes, max: maxValueBytes),
            let namespace = GameSkinLimits.rangedBytes(
                json["namespaceMaxBytes"], default: defaults.namespaceMaxBytes,
                min: minNamespaceBytes, max: maxNamespaceBytes)
        else { return .defaults }
        return GameStorageLimits(valueMaxBytes: value, namespaceMaxBytes: namespace)
    }
}

/// `gamification.measurement`: the cutoffs the device-tier level math reads.
/// Mirrors the `gamification.measurement` section the backend sends (see
/// `backend/src/services/digia-engage/sdk/gamificationConfig.ts`, the source
/// of truth); until the backend ships it, every install runs on these
/// defaults, which equal the long-standing hardcoded cutoffs. Absent keys
/// take their default; a malformed or out-of-range value falls the whole
/// section back to the defaults (like `deviceTier`), never half-applies, and
/// never throws.
///
/// Only some fields drive iOS math: the RAM bands, the battery bands and the
/// RAM CPU caps feed `GameDeviceInfo`'s approximations, and `lowRamDeviceMb`
/// synthesizes `isLowRamDevice`. The heap bands, pressure ratios, CPU score
/// bands and heap CPU caps have no iOS API behind them (no heap class, no
/// per-core tables); they are parsed for cross-stack parity and ignored here.
/// Adding a field is additive: old SDKs ignore keys they don't know.
struct GameMeasurementThresholds: Equatable, Sendable {
    var ramLowGb: Double
    var ramMidGb: Double
    var ramHighGb: Double
    var heapLowMb: Int
    var heapMidMb: Int
    var heapHighMb: Int
    var heapPressureRatio: Double
    var availThresholdFactor: Double
    var batteryHigh: Int
    var batteryHighCharging: Int
    var batteryMid: Int
    var batteryMidCharging: Int
    var batteryLow: Int
    var batteryLowCharging: Int
    var cpuScoreLow: Double
    var cpuScoreMid: Double
    var cpuScoreHigh: Double
    var cpuCapRamLowGb: Double
    var cpuCapRamMidGb: Double
    var cpuCapHeapLow: Int
    var cpuCapHeapMid: Int
    /// When set, `isLowRamDevice` is `totalRamInMb < lowRamDeviceMb`. Absent
    /// (nil) leaves the fact missing, today's iOS behavior.
    var lowRamDeviceMb: Int?

    static let minGb = 0.5
    static let maxGb = 32.0
    static let minMb = 16
    static let maxMb = 1024
    static let minRatio = 0.0
    static let maxRatio = 5.0
    static let minBattery = 0
    static let maxBattery = 100
    static let minCpuScore = 1.0
    static let maxCpuScore = 200.0
    static let minLowRamDeviceMb = 256
    static let maxLowRamDeviceMb = 32768

    static let defaults = GameMeasurementThresholds(
        ramLowGb: 2.8, ramMidGb: 6.9, ramHighGb: 10.5,
        heapLowMb: 128, heapMidMb: 160, heapHighMb: 256,
        heapPressureRatio: 0.75, availThresholdFactor: 1.5,
        batteryHigh: 80, batteryHighCharging: 70,
        batteryMid: 55, batteryMidCharging: 50,
        batteryLow: 40, batteryLowCharging: 35,
        cpuScoreLow: 20, cpuScoreMid: 34, cpuScoreHigh: 56,
        cpuCapRamLowGb: 2.8, cpuCapRamMidGb: 3.6,
        cpuCapHeapLow: 100, cpuCapHeapMid: 160,
        lowRamDeviceMb: nil
    )

    static func parse(_ json: [String: Any]?) -> GameMeasurementThresholds {
        guard let json else { return .defaults }
        guard let lowRamDeviceMb = lowRamMb(json["lowRamDeviceMb"]),
            let ramLowGb = ratio(json["ramLowGb"], default: defaults.ramLowGb, min: minGb, max: maxGb),
            let ramMidGb = ratio(json["ramMidGb"], default: defaults.ramMidGb, min: minGb, max: maxGb),
            let ramHighGb = ratio(json["ramHighGb"], default: defaults.ramHighGb, min: minGb, max: maxGb),
            let heapLowMb = whole(json["heapLowMb"], default: defaults.heapLowMb, min: minMb, max: maxMb),
            let heapMidMb = whole(json["heapMidMb"], default: defaults.heapMidMb, min: minMb, max: maxMb),
            let heapHighMb = whole(json["heapHighMb"], default: defaults.heapHighMb, min: minMb, max: maxMb),
            let heapPressureRatio = ratio(
                json["heapPressureRatio"], default: defaults.heapPressureRatio, min: minRatio, max: maxRatio),
            let availThresholdFactor = ratio(
                json["availThresholdFactor"], default: defaults.availThresholdFactor,
                min: minRatio, max: maxRatio),
            let batteryHigh = whole(
                json["batteryHigh"], default: defaults.batteryHigh, min: minBattery, max: maxBattery),
            let batteryHighCharging = whole(
                json["batteryHighCharging"], default: defaults.batteryHighCharging,
                min: minBattery, max: maxBattery),
            let batteryMid = whole(
                json["batteryMid"], default: defaults.batteryMid, min: minBattery, max: maxBattery),
            let batteryMidCharging = whole(
                json["batteryMidCharging"], default: defaults.batteryMidCharging,
                min: minBattery, max: maxBattery),
            let batteryLow = whole(
                json["batteryLow"], default: defaults.batteryLow, min: minBattery, max: maxBattery),
            let batteryLowCharging = whole(
                json["batteryLowCharging"], default: defaults.batteryLowCharging,
                min: minBattery, max: maxBattery),
            let cpuScoreLow = ratio(
                json["cpuScoreLow"], default: defaults.cpuScoreLow, min: minCpuScore, max: maxCpuScore),
            let cpuScoreMid = ratio(
                json["cpuScoreMid"], default: defaults.cpuScoreMid, min: minCpuScore, max: maxCpuScore),
            let cpuScoreHigh = ratio(
                json["cpuScoreHigh"], default: defaults.cpuScoreHigh, min: minCpuScore, max: maxCpuScore),
            let cpuCapRamLowGb = ratio(
                json["cpuCapRamLowGb"], default: defaults.cpuCapRamLowGb, min: minGb, max: maxGb),
            let cpuCapRamMidGb = ratio(
                json["cpuCapRamMidGb"], default: defaults.cpuCapRamMidGb, min: minGb, max: maxGb),
            let cpuCapHeapLow = whole(
                json["cpuCapHeapLow"], default: defaults.cpuCapHeapLow, min: minMb, max: maxMb),
            let cpuCapHeapMid = whole(
                json["cpuCapHeapMid"], default: defaults.cpuCapHeapMid, min: minMb, max: maxMb)
        else { return .defaults }
        return GameMeasurementThresholds(
            ramLowGb: ramLowGb, ramMidGb: ramMidGb, ramHighGb: ramHighGb,
            heapLowMb: heapLowMb, heapMidMb: heapMidMb, heapHighMb: heapHighMb,
            heapPressureRatio: heapPressureRatio, availThresholdFactor: availThresholdFactor,
            batteryHigh: batteryHigh, batteryHighCharging: batteryHighCharging,
            batteryMid: batteryMid, batteryMidCharging: batteryMidCharging,
            batteryLow: batteryLow, batteryLowCharging: batteryLowCharging,
            cpuScoreLow: cpuScoreLow, cpuScoreMid: cpuScoreMid, cpuScoreHigh: cpuScoreHigh,
            cpuCapRamLowGb: cpuCapRamLowGb, cpuCapRamMidGb: cpuCapRamMidGb,
            cpuCapHeapLow: cpuCapHeapLow, cpuCapHeapMid: cpuCapHeapMid,
            lowRamDeviceMb: lowRamDeviceMb
        )
    }

    /// Absent reads as the default; a present value must be a finite number
    /// inside `[min, max]` — the backend's typo guards. Anything else is nil,
    /// failing the whole section.
    private static func ratio(_ raw: Any?, default fallback: Double, min: Double, max: Double) -> Double? {
        guard let raw else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= min, value <= max else { return nil }
        return value
    }

    /// Absent reads as the default; a present value must be a finite whole
    /// number inside `[min, max]`. Anything else is nil, failing the whole
    /// section.
    private static func whole(_ raw: Any?, default fallback: Int, min: Int, max: Int) -> Int? {
        GameSkinLimits.rangedBytes(raw, default: fallback, min: min, max: max)
    }

    /// Absent, null or blank reads as unset (nil), keeping `isLowRamDevice`
    /// missing. A present number must be a finite whole number of megabytes
    /// inside 256…32768; anything else is nil, failing the whole section.
    private static func lowRamMb(_ raw: Any?) -> Int?? {
        guard let raw else { return .some(nil) }
        if raw is NSNull { return .some(nil) }
        if let text = raw as? String {
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .some(nil)
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == floor(value),
            value >= Double(minLowRamDeviceMb), value <= Double(maxLowRamDeviceMb)
        else { return nil }
        return .some(Int(value))
    }
}

struct SdkConfig: Equatable, Sendable {
    let healthEnabled: Bool
    let healthSessionCap: Int
    /// The app-event upload switch, rate, burst, blocklist and limits.
    let appEvents: AppEventUploadPolicy
    /// The game prewarm switches. Off unless the response turns them on.
    let gamePrewarm: GamePrewarmConfig
    /// How a device is placed in a game tier; the built-in default unless the backend sends one.
    let deviceTier: DeviceTierConfig
    /// The cutoffs the device-tier level math reads; today's hardcoded numbers until the backend sends them.
    let gameMeasurement: GameMeasurementThresholds
    /// Skin download, skin cache and bridge intake caps.
    let gameSkinLimits: GameSkinLimits
    /// Per-skin storage quotas.
    let gameStorageLimits: GameStorageLimits

    init(
        healthEnabled: Bool, healthSessionCap: Int, appEvents: AppEventUploadPolicy = .unlimited,
        gamePrewarm: GamePrewarmConfig = .off, deviceTier: DeviceTierConfig = .default,
        gameMeasurement: GameMeasurementThresholds = .defaults,
        gameSkinLimits: GameSkinLimits = .defaults, gameStorageLimits: GameStorageLimits = .defaults
    ) {
        self.healthEnabled = healthEnabled
        self.healthSessionCap = healthSessionCap
        self.appEvents = appEvents
        self.gamePrewarm = gamePrewarm
        self.deviceTier = deviceTier
        self.gameMeasurement = gameMeasurement
        self.gameSkinLimits = gameSkinLimits
        self.gameStorageLimits = gameStorageLimits
    }

    /// What the SDK runs on with no cache and no answer. A test pins it to the shared fixture.
    static let defaults = SdkConfig(
        healthEnabled: true, healthSessionCap: HealthSink.defaultSessionCap, appEvents: .unlimited)

    /// Reads each field on its own. Numbers take the first valid value of fetched, cached,
    /// then the default; a limit below 1 is ignored. A switch comes from the fetched
    /// response alone when there is one, and is off only for an explicit `false`.
    static func resolve(fetched: [String: Any]? = nil, cached: [String: Any]? = nil) -> SdkConfig {
        let sources = [fetched, cached]
        let primary = fetched ?? cached

        func section(_ source: [String: Any]?, _ path: [String]) -> Any? {
            var node: Any? = source
            for key in path {
                node = (node as? [String: Any])?[key]
            }
            return node
        }
        func number(_ path: [String], min: Int, fallback: Int) -> Int {
            sources.lazy.compactMap { count(section($0, path), min: min) }.first ?? fallback
        }
        func flag(_ path: [String]) -> Bool {
            (section(primary, path) as? NSNumber).flatMap(boolean) ?? true
        }
        /// An opt-in switch: on only for an explicit `true`.
        func optIn(_ path: [String]) -> Bool {
            (section(primary, path) as? NSNumber).flatMap(boolean) ?? false
        }

        let limits = ["appEvents", "limits"]
        let defaults = AppEventLimits.defaults
        let blocked = section(primary, ["appEvents", "blockedNames"]) as? [Any]
        let prewarm = ["gamification", "prewarm"]
        return SdkConfig(
            healthEnabled: flag(["sdkHealth", "enabled"]),
            healthSessionCap: number(["sdkHealth", "sessionCap"], min: 0, fallback: HealthSink.defaultSessionCap),
            appEvents: AppEventUploadPolicy(
                enabled: flag(["appEvents", "upload"]),
                ratePerMinute: number(["appEvents", "ratePerMinute"], min: 0, fallback: 0),
                burst: number(["appEvents", "burst"], min: 0, fallback: 0),
                blockedNames: Set(blocked?.compactMap { $0 as? String } ?? []),
                limits: AppEventLimits(
                    nameMaxLength: number(limits + ["nameMaxLength"], min: 1, fallback: defaults.nameMaxLength),
                    maxProperties: number(limits + ["maxProperties"], min: 1, fallback: defaults.maxProperties),
                    propertyKeyMaxLength: number(
                        limits + ["propertyKeyMaxLength"], min: 1, fallback: defaults.propertyKeyMaxLength),
                    stringMaxLength: number(
                        limits + ["stringMaxLength"], min: 1, fallback: defaults.stringMaxLength),
                    listMaxItems: number(limits + ["listMaxItems"], min: 1, fallback: defaults.listMaxItems)
                )
            ),
            gamePrewarm: GamePrewarmConfig(
                engine: optIn(prewarm + ["engine"]),
                game: optIn(prewarm + ["game"]),
                tiers: tiers(section(primary, prewarm + ["tiers"]))
            ),
            deviceTier: DeviceTierConfig.parse(section(primary, ["gamification", "deviceTier"]) as? [String: Any]),
            gameMeasurement: GameMeasurementThresholds.parse(
                section(primary, ["gamification", "measurement"]) as? [String: Any]),
            gameSkinLimits: GameSkinLimits.parse(
                section(primary, ["gamification", "limits"]) as? [String: Any]),
            gameStorageLimits: GameStorageLimits.parse(
                section(primary, ["gamification", "storage"]) as? [String: Any])
        )
    }

    /// A non-empty list of known tiers, else the default; one unknown tier falls back whole.
    private static func tiers(_ raw: Any?) -> Set<String> {
        guard let array = raw as? [Any], !array.isEmpty else { return GamePrewarmConfig.defaultTiers }
        let tiers = array.compactMap { $0 as? String }
        guard tiers.count == array.count, tiers.allSatisfy(DeviceTierConfig.tiers.contains) else {
            return GamePrewarmConfig.defaultTiers
        }
        return Set(tiers)
    }

    private static func boolean(_ number: NSNumber) -> Bool? {
        CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }

    private static func count(_ raw: Any?, min: Int) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == floor(value),
              (Double(min)...Double(Int32.max)).contains(value)
        else { return nil }
        return number.intValue
    }
}

/// `gamification.prewarm`: `engine` keeps one blank game web view warm, `game` loads a
/// whole game ahead of the tap (and the Direct load alongside the grant). Every switch is
/// off unless the response says `true`, so a missing block leaves today's behaviour. Only a
/// device whose game tier is in `tiers` is eligible.
struct GamePrewarmConfig: Equatable, Sendable {
    var engine = false
    var game = false
    var tiers: Set<String> = GamePrewarmConfig.defaultTiers

    static let defaultTiers: Set<String> = ["high"]
    static let off = GamePrewarmConfig()

    /// Eligible for the engine prewarm: `engine` on and the tier allowed.
    func allowsEngine(tier: String) -> Bool {
        engine && tiers.contains(tier)
    }

    /// Eligible for the game prewarm and the Direct parallel load.
    func allowsGame(tier: String) -> Bool {
        game && tiers.contains(tier)
    }
}

/// The cached config for one project, and the once-per-launch fetch of the next.
/// Nothing here throws: a failure leaves the cache and whatever is applied as they were.
@MainActor
final class SdkConfigStore {
    static let fetchTimeout: TimeInterval = 10

    private let storage: LocalStorage
    private let key: String
    private let timeout: TimeInterval
    private let cachedRaw: [String: Any]?

    init(storage: LocalStorage, projectKey: String, timeout: TimeInterval = SdkConfigStore.fetchTimeout) {
        self.storage = storage
        self.key = projectKey
        self.timeout = timeout
        self.cachedRaw = Self.read(storage, projectKey)
    }

    /// The cached config, or nil on a first install or an unreadable save.
    var cached: SdkConfig? {
        cachedRaw.map { SdkConfig.resolve(cached: $0) }
    }

    /// Calls `getSdkConfig`. Returns the config to apply, or nil when the call failed;
    /// then nothing was saved.
    func fetch(using client: any NetworkClient) async -> SdkConfig? {
        guard let url = URL(string: DigiaEndpoints.sdkConfig) else { return nil }
        let request = NetworkRequest(
            url: url, method: .post, body: Data("{}".utf8), connectTimeout: timeout, readTimeout: timeout)
        do {
            let response = try await Self.race(timeout) { try await client.execute(request: request) }
            guard response.isSuccessful else {
                log.w("SDK config not applied: HTTP \(response.statusCode)")
                return nil
            }
            guard let payload = Self.payload(response.body ?? Data()) else {
                log.w("SDK config not applied: the response is not an object")
                return nil
            }
            if let saved = try? JSONSerialization.data(withJSONObject: payload),
               let text = String(data: saved, encoding: .utf8) {
                storage.set(text, forKey: key)
            }
            return SdkConfig.resolve(fetched: payload, cached: cachedRaw)
        } catch {
            log.w("SDK config not applied: the request failed", error: error)
            return nil
        }
    }

    private static func read(_ storage: LocalStorage, _ key: String) -> [String: Any]? {
        guard let text = storage.string(forKey: key),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        else { return nil }
        return object as? [String: Any]
    }

    /// The body as an object, unwrapped from the `{data: {response: …}}` envelope the
    /// other SDK endpoints use when it has one.
    private static func payload(_ body: Data) -> [String: Any]? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        let data = root["data"] as? [String: Any]
        if data?["response"] != nil {
            return data?["response"] as? [String: Any]
        }
        if root["response"] != nil {
            return root["response"] as? [String: Any]
        }
        if data != nil || root["error"] != nil {
            return nil
        }
        return root
    }

    private struct TimedOut: Error {}

    private static func race(
        _ seconds: TimeInterval, _ call: @escaping @Sendable () async throws -> NetworkResponse
    ) async throws -> NetworkResponse {
        try await withThrowingTaskGroup(of: NetworkResponse.self) { group in
            group.addTask { try await call() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
