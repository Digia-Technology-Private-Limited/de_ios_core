import Foundation
import Testing

@testable import DigiaEngage

/// The SDK config on the real `initialize()`: the cache applies at once, the fetch runs
/// unawaited, and a first install holds health events until the call answers.
@MainActor
@Suite("SDKInstance SDK config", .serialized)
struct SDKInstanceSdkConfigTests {

    private let apiKey = "test_key"
    /// Stamped on this test's health records. The analytics queue is one store shared by every
    /// SDK instance in the process, so counting by event name alone also counts parallel suites'.
    private let runKey = "sdk-config-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!
    }

    private func makeInstance(
        defaults: UserDefaults, network: ConfigNetworkClient, sink: HealthSink
    ) -> SDKInstance {
        SDKInstance(
            defaults: defaults,
            legacyDefaults: makeDefaults(),
            makeNetworkClient: { _ in network },
            healthSink: sink
        )
    }

    private func seedCache(_ defaults: UserDefaults, _ json: String) {
        defaults.set(1, forKey: "storage.version")
        defaults.set(json, forKey: "sdk_config.\(apiKey)")
    }

    private func healthRecord(_ key: String) -> TimelineRecord {
        TimelineRecord(
            timestamp: Date(timeIntervalSince1970: 0), severity: .error, tag: "DIGIA", message: "m",
            stage: .parse, reason: TimelineReason.malformedCampaignSkipped, campaignKey: "\(runKey)-\(key)",
            extras: [:])
    }

    /// This test's health events queued so far. With [expected], keeps looking for up to 3 s until
    /// that many arrive, so a loaded simulator's slow enqueue is not read as nothing sent.
    private func sentHealthEvents(_ sdk: SDKInstance, awaiting expected: Int = 0) async throws -> Int {
        try await Task.sleep(nanoseconds: 150_000_000)
        let analytics = try #require(sdk.services?.analyticsService)
        let deadline = Date().addingTimeInterval(3)
        while true {
            let count = await analytics.queue.peek(maxCount: 100)
                .filter {
                    ($0.payload["event_name"] as? String) == HealthSink.eventName
                        && ($0.payload["campaign_key"] as? String)?.hasPrefix(runKey) == true
                }
                .count
            if count >= expected || Date() > deadline { return count }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("the config call runs on every initialize, even with a cache")
    func callsEveryInitialize() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":false}}"#)
        let network = ConfigNetworkClient()
        let sdk = makeInstance(defaults: defaults, network: network, sink: HealthSink())

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        #expect(network.configCalls == 1)
        network.answer("{}")
    }

    @Test("a cached switch-off applies before the call answers")
    func cachedSwitchOffAppliesAtInit() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":false}}"#)
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))

        #expect(!sink.isRegistered)
        network.answer(#"{"sdkHealth":{"enabled":false}}"#)
    }

    @Test("a cached config sends health at once without waiting for the call")
    func cachedConfigSendsAtOnce() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":true,"sessionCap":5}}"#)
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))

        #expect(try await sentHealthEvents(sdk, awaiting: 1) == 1)
        network.answer("{}")
    }

    @Test("first install holds health until the call answers")
    func firstInstallHoldsEvents() async throws {
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: makeDefaults(), network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))
        #expect(try await sentHealthEvents(sdk) == 0)

        network.answer(#"{"sdkHealth":{"enabled":true}}"#)
        await sdk.sdkConfigFetchTask?.value
        #expect(try await sentHealthEvents(sdk, awaiting: 1) == 1)
    }

    @Test("first install with switch-off in the answer drops the held health")
    func firstInstallSwitchedOff() async throws {
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: makeDefaults(), network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))
        network.answer(#"{"sdkHealth":{"enabled":false}}"#)
        await sdk.sdkConfigFetchTask?.value

        #expect(!sink.isRegistered)
        #expect(try await sentHealthEvents(sdk) == 0)
    }

    @Test("first install with a failed call runs on defaults and sends the held health")
    func firstInstallFailureUsesDefaults() async throws {
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: makeDefaults(), network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))
        network.fail()
        await sdk.sdkConfigFetchTask?.value

        #expect(try await sentHealthEvents(sdk, awaiting: 1) == 1)
    }

    @Test("a failed call leaves the cached switch-off in force")
    func failureKeepsCachedOff() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":false}}"#)
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        network.fail()
        await sdk.sdkConfigFetchTask?.value

        #expect(!sink.isRegistered)
    }

    @Test("a fetched switch-on re-registers a sink the cache had turned off")
    func fetchedOnReRegisters() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":false}}"#)
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        #expect(!sink.isRegistered)

        network.answer(#"{"sdkHealth":{"enabled":true}}"#)
        await sdk.sdkConfigFetchTask?.value

        #expect(sink.isRegistered)
        sink.emit(healthRecord("a"))
        #expect(try await sentHealthEvents(sdk, awaiting: 1) == 1)
    }

    @Test("a fetched config replaces the cache for the next launch")
    func fetchedReplacesCache() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":false}}"#)
        let network = ConfigNetworkClient()
        let sdk = makeInstance(defaults: defaults, network: network, sink: HealthSink())

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        network.answer(#"{"sdkHealth":{"enabled":true,"sessionCap":5}}"#)
        await sdk.sdkConfigFetchTask?.value

        let next = SdkConfigStore(
            storage: UserDefaultsLocalStorage(defaults: defaults).scoped("sdk_config"),
            projectKey: apiKey)
        #expect(next.cached == SdkConfig(healthEnabled: true, healthSessionCap: 5))
    }
}

/// Answers the bundle at once and holds `getSdkConfig` until the test answers or fails it.
/// An answer given before the request arrives is kept for it.
final class ConfigNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NetworkResponse, Error>?
    private var early: Result<NetworkResponse, Error>?
    private var calls = 0
    private let bundle: String

    init(bundle: String = #"{"response":{"campaigns":[]}}"#) {
        self.bundle = bundle
    }

    var configCalls: Int {
        lock.withLock { calls }
    }

    func answer(_ body: String) {
        resume(.success(NetworkResponse(statusCode: 200, headers: [:], body: Data(body.utf8), isSuccessful: true)))
    }

    func fail() {
        resume(.failure(URLError(.notConnectedToInternet)))
    }

    private func resume(_ result: Result<NetworkResponse, Error>) {
        let waiter: CheckedContinuation<NetworkResponse, Error>? = lock.withLock {
            let waiter = self.waiter
            self.waiter = nil
            if waiter == nil { early = result }
            return waiter
        }
        waiter?.resume(with: result)
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let url = request.url.absoluteString
        if url.hasSuffix("/getCampaignBundle") {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data(bundle.utf8), isSuccessful: true)
        }
        guard url.hasSuffix("/getSdkConfig") else {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8), isSuccessful: true)
        }
        lock.withLock { calls += 1 }
        return try await withCheckedThrowingContinuation { continuation in
            let earlyResult: Result<NetworkResponse, Error>? = lock.withLock {
                if let early {
                    return early
                } else {
                    waiter = continuation
                    return nil
                }
            }
            if let earlyResult {
                continuation.resume(with: earlyResult)
            }
        }
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        MockNetworkClient().openSseStream(request: request, handler: handler)
    }
}
