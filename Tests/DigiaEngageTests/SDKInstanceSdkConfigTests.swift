import Foundation
import Testing

@testable import DigiaEngage

/// The SDK config on the real `initialize()`: the cache applies at once, the fetch runs
/// unawaited, and a first install holds health events until the call answers.
@MainActor
@Suite("SDKInstance SDK config", .serialized)
struct SDKInstanceSdkConfigTests {

    private let apiKey = "test_key"

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
            stage: .parse, reason: TimelineReason.malformedCampaignSkipped, campaignKey: key, extras: [:])
    }

    private func sentHealthEvents(_ sdk: SDKInstance) async throws -> Int {
        try await Task.sleep(nanoseconds: 150_000_000)
        let analytics = try #require(sdk.services?.analyticsService)
        return await analytics.queue.peek(maxCount: 100)
            .filter { ($0.payload["event_name"] as? String) == HealthSink.eventName }.count
    }

    @Test("a cached switch-off applies before the fetch answers")
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

    @Test("a cached config lets health events through without waiting for the call")
    func cachedConfigSendsAtOnce() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":true,"sessionCap":5}}"#)
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))

        #expect(try await sentHealthEvents(sdk) == 1)
        network.answer("{}")
    }

    @Test("first install holds health events until the config call answers")
    func firstInstallHoldsEvents() async throws {
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: makeDefaults(), network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))
        #expect(try await sentHealthEvents(sdk) == 0)

        network.answer(#"{"sdkHealth":{"enabled":true}}"#)
        await sdk.sdkConfigFetchTask?.value
        #expect(try await sentHealthEvents(sdk) == 1)
    }

    @Test("first install drops held events when the answer switches health off")
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

    @Test("first install with a failed call runs on the defaults and sends the held events")
    func firstInstallFailureUsesDefaults() async throws {
        let network = ConfigNetworkClient()
        let sink = HealthSink()
        let sdk = makeInstance(defaults: makeDefaults(), network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        sink.emit(healthRecord("a"))
        network.fail()
        await sdk.sdkConfigFetchTask?.value

        #expect(try await sentHealthEvents(sdk) == 1)
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
        #expect(try await sentHealthEvents(sdk) == 1)
    }

    @Test("the campaign bundle's health fields are ignored")
    func bundleHealthFieldsIgnored() async throws {
        let defaults = makeDefaults()
        seedCache(defaults, #"{"sdkHealth":{"enabled":true}}"#)
        let network = ConfigNetworkClient(bundle: #"{"response":{"campaigns":[],"sdkHealth":false}}"#)
        let sink = HealthSink()
        let sdk = makeInstance(defaults: defaults, network: network, sink: sink)

        try await sdk.initialize(DigiaConfig(apiKey: apiKey))
        for _ in 0..<100 where sdk.sdkState == .initializing { try await Task.sleep(nanoseconds: 10_000_000) }

        #expect(sink.isRegistered)
        network.answer("{}")
    }
}

/// Answers the bundle at once and holds `getSdkConfig` until the test answers or fails it.
/// An answer given before the request arrives is kept for it.
final class ConfigNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NetworkResponse, Error>?
    private var early: Result<NetworkResponse, Error>?
    private let bundle: String

    init(bundle: String = #"{"response":{"campaigns":[]}}"#) {
        self.bundle = bundle
    }

    func answer(_ body: String) {
        resume(.success(NetworkResponse(statusCode: 200, headers: [:], body: Data(body.utf8), isSuccessful: true)))
    }

    func fail() {
        resume(.failure(URLError(.notConnectedToInternet)))
    }

    private func resume(_ result: Result<NetworkResponse, Error>) {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        if waiter == nil { early = result }
        lock.unlock()
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
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(with: early)
            } else {
                waiter = continuation
                lock.unlock()
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
