import Foundation

private let log = DigiaLogger()

/// The flags and limits the backend can change without an SDK release.
/// `sdkHealth`, `appEvents`, `gamification.prewarm`, `gamification.deviceTier`,
/// `gamification.limits` and `gamification.storage` are read here;
/// the saved response is kept whole.
/// `gamification.limits`: caps for skin downloads, the skin cache and the
/// bridge intake. Every present value clamps into its range; absent keys take
/// their default. A non-numeric value falls the whole section back to the
/// defaults (like `deviceTier`), never half-applies, and never throws.
struct GameSkinLimits: Equatable, Sendable {
    /// One self-contained skin file. Default is the old whole-bundle budget
    /// (3 MB + 10%); clamps 1…20 MB.
    var skinFileMaxBytes: Int
    /// The whole skin cache across entries. Default 16 MB; clamps 8…64 MB.
    var skinCacheMaxBytes: Int
    /// One skin bridge message. Default 64 KB; clamps 16…256 KB.
    var bridgeMessageMaxBytes: Int

    static let minSkinFileBytes = 1 * 1024 * 1024
    static let maxSkinFileBytes = 20 * 1024 * 1024
    static let minSkinCacheBytes = 8 * 1024 * 1024
    static let maxSkinCacheBytes = 64 * 1024 * 1024
    static let minBridgeMessageBytes = 16 * 1024
    static let maxBridgeMessageBytes = 256 * 1024

    static let defaults = GameSkinLimits(
        skinFileMaxBytes: 3 * 1024 * 1024 + (3 * 1024 * 1024) / 10,
        skinCacheMaxBytes: 16 * 1024 * 1024,
        bridgeMessageMaxBytes: 64 * 1024
    )

    static func parse(_ json: [String: Any]?) -> GameSkinLimits {
        guard let json else { return .defaults }
        guard let file = clampedBytes(
            json["skinFileMaxBytes"], default: defaults.skinFileMaxBytes,
            min: minSkinFileBytes, max: maxSkinFileBytes),
            let cache = clampedBytes(
                json["skinCacheMaxBytes"], default: defaults.skinCacheMaxBytes,
                min: minSkinCacheBytes, max: maxSkinCacheBytes),
            let message = clampedBytes(
                json["bridgeMessageMaxBytes"], default: defaults.bridgeMessageMaxBytes,
                min: minBridgeMessageBytes, max: maxBridgeMessageBytes)
        else { return .defaults }
        return GameSkinLimits(
            skinFileMaxBytes: file, skinCacheMaxBytes: cache, bridgeMessageMaxBytes: message)
    }

    /// Absent reads as the default; a finite whole number clamps; anything else
    /// is nil, failing the whole section. The range check runs on the double
    /// before converting, so a huge value clamps instead of trapping `Int`.
    static func clampedBytes(_ raw: Any?, default fallback: Int, min: Int, max: Int) -> Int? {
        guard let raw else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == floor(value) else { return nil }
        if value <= Double(min) { return min }
        if value >= Double(max) { return max }
        return Int(value)
    }
}

/// `gamification.storage`: the per-skin key-value quotas. Same whole-fallback
/// rule as `limits`: absent keys take their default, a non-numeric value
/// falls the whole section back to the defaults.
struct GameStorageLimits: Equatable, Sendable {
    /// One storage value. Default 16 KB; clamps 4…256 KB.
    var valueMaxBytes: Int
    /// One skin namespace across keys. Default 64 KB; clamps 16 KB…1 MB.
    var namespaceMaxBytes: Int

    static let minValueBytes = 4 * 1024
    static let maxValueBytes = 256 * 1024
    static let minNamespaceBytes = 16 * 1024
    static let maxNamespaceBytes = 1024 * 1024

    static let defaults = GameStorageLimits(valueMaxBytes: 16 * 1024, namespaceMaxBytes: 64 * 1024)

    static func parse(_ json: [String: Any]?) -> GameStorageLimits {
        guard let json else { return .defaults }
        guard let value = GameSkinLimits.clampedBytes(
            json["valueMaxBytes"], default: defaults.valueMaxBytes,
            min: minValueBytes, max: maxValueBytes),
            let namespace = GameSkinLimits.clampedBytes(
                json["namespaceMaxBytes"], default: defaults.namespaceMaxBytes,
                min: minNamespaceBytes, max: maxNamespaceBytes)
        else { return .defaults }
        return GameStorageLimits(valueMaxBytes: value, namespaceMaxBytes: namespace)
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
    /// Skin download, skin cache and bridge intake caps.
    let gameSkinLimits: GameSkinLimits
    /// Per-skin storage quotas.
    let gameStorageLimits: GameStorageLimits
    /// The image disk cap the owned `DigiaImagePipeline.imageCache` runs with.
    let imageDiskCacheBytes: Int
    /// The Lottie HTTP disk cap the download session's `URLCache` runs with.
    let lottieDiskCacheBytes: Int

    /// The single default max for both media disk caches: 100 MiB. The backend
    /// sends a plain byte count per cache; `URLCache` only stores a response
    /// under about 5% of its capacity, so this keeps typical Lottie files cacheable.
    static let defaultMediaDiskCacheBytes = 100 * 1024 * 1024

    init(
        healthEnabled: Bool,
        healthSessionCap: Int,
        appEvents: AppEventUploadPolicy = .unlimited,
        gamePrewarm: GamePrewarmConfig = .off, deviceTier: DeviceTierConfig = .default,
        gameSkinLimits: GameSkinLimits = .defaults, gameStorageLimits: GameStorageLimits = .defaults,
        imageDiskCacheBytes: Int = defaultMediaDiskCacheBytes,
        lottieDiskCacheBytes: Int = defaultMediaDiskCacheBytes
    ) {
        self.healthEnabled = healthEnabled
        self.healthSessionCap = healthSessionCap
        self.appEvents = appEvents
        self.gamePrewarm = gamePrewarm
        self.deviceTier = deviceTier
        self.gameSkinLimits = gameSkinLimits
        self.gameStorageLimits = gameStorageLimits
        self.imageDiskCacheBytes = imageDiskCacheBytes
        self.lottieDiskCacheBytes = lottieDiskCacheBytes
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
            gameSkinLimits: GameSkinLimits.parse(
                section(primary, ["gamification", "limits"]) as? [String: Any]),
            gameStorageLimits: GameStorageLimits.parse(
                section(primary, ["gamification", "storage"]) as? [String: Any]),
            imageDiskCacheBytes: number(["media", "imageDiskCacheBytes"], min: 1, fallback: Self.defaultMediaDiskCacheBytes),
            lottieDiskCacheBytes: number(["media", "lottieDiskCacheBytes"], min: 1, fallback: Self.defaultMediaDiskCacheBytes)
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
