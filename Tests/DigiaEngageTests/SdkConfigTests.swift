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

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        throw URLError(.timedOut)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        MockNetworkClient().openSseStream(request: request, handler: handler)
    }
}
