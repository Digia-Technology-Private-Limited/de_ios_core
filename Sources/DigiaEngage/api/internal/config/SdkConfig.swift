import Foundation

private let log = DigiaLogger()

/// The flags and limits the backend can change without an SDK release.
/// `sdkHealth` and `appEvents` are read here; the saved response is kept whole.
struct SdkConfig: Equatable, Sendable {
    let healthEnabled: Bool
    let healthSessionCap: Int
    /// The app-event upload switch, rate, burst, blocklist and limits.
    let appEvents: AppEventUploadPolicy
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
        imageDiskCacheBytes: Int = defaultMediaDiskCacheBytes,
        lottieDiskCacheBytes: Int = defaultMediaDiskCacheBytes
    ) {
        self.healthEnabled = healthEnabled
        self.healthSessionCap = healthSessionCap
        self.appEvents = appEvents
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

        let limits = ["appEvents", "limits"]
        let defaults = AppEventLimits.defaults
        let blocked = section(primary, ["appEvents", "blockedNames"]) as? [Any]
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
            imageDiskCacheBytes: number(["media", "imageDiskCacheBytes"], min: 1, fallback: Self.defaultMediaDiskCacheBytes),
            lottieDiskCacheBytes: number(["media", "lottieDiskCacheBytes"], min: 1, fallback: Self.defaultMediaDiskCacheBytes)
        )
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
