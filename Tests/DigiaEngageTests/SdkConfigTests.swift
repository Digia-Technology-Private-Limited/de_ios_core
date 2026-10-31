import Foundation
import Testing

@testable import DigiaEngage

private func object(_ json: String) -> [String: Any] {
    try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
}

@Suite("SdkConfig resolve")
struct SdkConfigResolveTests {

    @Test("built-in defaults are health on, 20 events per session")
    func builtInDefaults() {
        #expect(SdkConfig.defaults.healthEnabled == true)
        #expect(SdkConfig.defaults.healthSessionCap == 20)
    }

    @Test("the switch is off only for an explicit false")
    func switchOffOnlyForFalse() {
        func enabled(_ health: String) -> Bool {
            SdkConfig.resolve(fetched: object(#"{"sdkHealth":\#(health)}"#)).healthEnabled
        }
        #expect(enabled(#"{"enabled":false}"#) == false)
        for on in [#"{"enabled":true}"#, "{}", #"{"enabled":null}"#, #"{"enabled":"false"}"#, #"{"enabled":0}"#,
                   "[]", #""off""#, "null"] {
            #expect(enabled(on), "\(on) must leave the switch on")
        }
    }

    @Test("a fetched config without the switch turns it on, whatever the cache said")
    func fetchedSwitchIgnoresCache() {
        let cached = object(#"{"sdkHealth":{"enabled":false}}"#)
        #expect(SdkConfig.resolve(fetched: object("{}"), cached: cached).healthEnabled)
        #expect(SdkConfig.resolve(fetched: nil, cached: cached).healthEnabled == false)
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
        for bad in ["-1", #""5""#, "true", "null", "[]"] {
            #expect(cap(bad) == 7, "\(bad) must fall through to the cache")
        }
        #expect(SdkConfig.resolve(fetched: object("{}")).healthSessionCap == HealthSink.defaultSessionCap)
        #expect(SdkConfig.resolve().healthSessionCap == HealthSink.defaultSessionCap)
    }

    @Test("a malformed field costs only itself")
    func fieldsAreIndependent() {
        let config = SdkConfig.resolve(
            fetched: object(#"{"sdkHealth":{"enabled":false,"sessionCap":"many"},"appEvents":7}"#))
        #expect(config == SdkConfig(healthEnabled: false, healthSessionCap: HealthSink.defaultSessionCap))
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

    @Test("a valid response is applied, then read back by the next launch")
    func fetchPersists() async {
        let storage = storage()
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"sdkHealth":{"enabled":false,"sessionCap":4}}"#)

        let first = SdkConfigStore(storage: storage, projectKey: "k")
        #expect(first.cached == nil)
        let fetched = await first.fetch(using: client)

        #expect(fetched == SdkConfig(healthEnabled: false, healthSessionCap: 4))
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == fetched)
        #expect(SdkConfigStore(storage: storage, projectKey: "other").cached == nil)
    }

    @Test("a response in the data.response envelope is unwrapped")
    func envelopeUnwrapped() async {
        let client = MockNetworkClient()
        respond(client, status: 200, body: #"{"data":{"response":{"sdkHealth":{"sessionCap":9}}}}"#)
        let fetched = await SdkConfigStore(storage: storage(), projectKey: "k").fetch(using: client)
        #expect(fetched?.healthSessionCap == 9)
    }

    @Test("a failed call changes nothing and keeps the cached config")
    func failureKeepsCache() async {
        let storage = storage()
        let seed = MockNetworkClient()
        respond(seed, status: 200, body: #"{"sdkHealth":{"enabled":false,"sessionCap":4}}"#)
        let saved = await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: seed)

        for (status, body) in [(500, #"{"sdkHealth":{"enabled":true}}"#), (200, "[]"), (200, "not json")] {
            let client = MockNetworkClient()
            respond(client, status: status, body: body)
            let store = SdkConfigStore(storage: storage, projectKey: "k")
            #expect(await store.fetch(using: client) == nil)
            #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)
        }

        let broken = MockNetworkClient()
        broken.simulateTransportError(URLError(.notConnectedToInternet))
        #expect(await SdkConfigStore(storage: storage, projectKey: "k").fetch(using: broken) == nil)
        #expect(SdkConfigStore(storage: storage, projectKey: "k").cached == saved)
    }

    @Test("a call that never answers gives up at the timeout")
    func timesOut() async {
        let store = SdkConfigStore(storage: storage(), projectKey: "k", timeout: 0.1)
        let start = Date()
        #expect(await store.fetch(using: SilentNetworkClient()) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}

/// Never answers; ends only when its task is cancelled.
final class SilentNetworkClient: NetworkClient, @unchecked Sendable {
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
