import Foundation

private let log = DigiaLogger()

/// The flags and limits the backend can change without an SDK release.
/// Only `sdkHealth` is read here; the saved response is kept whole.
struct SdkConfig: Equatable, Sendable {
    let healthEnabled: Bool
    let healthSessionCap: Int

    /// What the SDK runs on with no cache and no answer. A test pins it to the shared fixture.
    static let defaults = SdkConfig(healthEnabled: true, healthSessionCap: HealthSink.defaultSessionCap)

    /// Reads each field on its own. The cap takes the first valid value of fetched, cached,
    /// then the default; the switch comes from the fetched response alone when there is one.
    static func resolve(fetched: [String: Any]? = nil, cached: [String: Any]? = nil) -> SdkConfig {
        let sections = [fetched, cached].map { $0?["sdkHealth"] as? [String: Any] }
        let switchSection = (fetched ?? cached)?["sdkHealth"] as? [String: Any]
        return SdkConfig(
            healthEnabled: (switchSection?["enabled"] as? NSNumber).flatMap(boolean) ?? true,
            healthSessionCap: sections.lazy.compactMap { count($0?["sessionCap"]) }.first
                ?? HealthSink.defaultSessionCap
        )
    }

    private static func boolean(_ number: NSNumber) -> Bool? {
        CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue : nil
    }

    private static func count(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              (0...Double(Int32.max)).contains(number.doubleValue)
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
        if let data = root["data"] as? [String: Any], let response = data["response"] { return response as? [String: Any] }
        if let response = root["response"] { return response as? [String: Any] }
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
