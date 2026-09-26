import Foundation
import Testing

@testable import DigiaEngage

/// `initialize()` returns once SDKServices is built; the campaign bundle is
/// fetched in the background (SD4). A trigger that arrives before the SDK is
/// ready is dropped at once, never held (SP5).
@MainActor
@Suite("SDKInstance initialize returns before the fetch", .serialized)
struct SDKInstanceEarlyInitTests {

    private func makeInstance(network: HeldBundleNetworkClient) -> SDKInstance {
        SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { _ in network }
        )
    }

    private func deliver(_ sdk: SDKInstance, _ campaignKey: String) -> PresentationRecorder {
        PresentationRecorder(
            sdk.deliver(CEPTriggerPayload(cepCampaignId: "cep-1", campaignKey: campaignKey, cepMetadata: [:]))
        )
    }

    private func waitUntilReady(_ sdk: SDKInstance) async throws {
        for _ in 0..<200 where sdk.sdkState != .ready {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sdk.sdkState == .ready)
    }

    @Test("initialize() completes while the fetch is still pending")
    func completesBeforeFetch() async throws {
        let network = HeldBundleNetworkClient()
        let sdk = makeInstance(network: network)

        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        #expect(sdk.services != nil)
        #expect(sdk.sdkState == .notInitialized)
        #expect(sdk.campaignStore.isEmpty)
        network.release(.success(Self.bundle(campaignKey: "launch")))
        try await waitUntilReady(sdk)
    }

    @Test("a trigger before ready settles dropped at once, with the reason for the state it met")
    func dropsBeforeReady() async throws {
        let network = HeldBundleNetworkClient()
        let sdk = makeInstance(network: network)

        // Never initialized.
        let beforeInit = deliver(sdk, "launch")
        #expect(beforeInit.isSettled)
        #expect(beforeInit.dropReason == .notInitialized)
        #expect(beforeInit.isHoldReleased)

        // Initializing: the fetch is still running.
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        let whileFetching = deliver(sdk, "launch")
        #expect(whileFetching.isSettled)
        #expect(whileFetching.dropReason == .notReady)
        #expect(whileFetching.isHoldReleased)

        // Nothing was held: the fetch landing shows nothing.
        network.release(.success(Self.bundle(campaignKey: "launch")))
        try await waitUntilReady(sdk)
        #expect(sdk.controller.activeNudge == nil)
    }

    @Test("a fetch failure reaches ready with an empty store and surfaces no error")
    func fetchFailureReachesReady() async throws {
        let network = HeldBundleNetworkClient()
        let sdk = makeInstance(network: network)
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        network.release(.failure(URLError(.notConnectedToInternet)))
        try await waitUntilReady(sdk)

        #expect(sdk.campaignStore.isEmpty)
    }

    private static func bundle(campaignKey: String) -> NetworkResponse {
        let campaign: [String: Any] = [
            "id": "\(campaignKey)-id",
            "campaignKey": campaignKey,
            "campaignType": "nudge",
            "templateConfig": [
                "container": ["displayType": "dialog"],
                "layout": ["type": "digia/column", "props": [:], "children": []],
            ],
        ]
        let body = try! JSONSerialization.data(withJSONObject: ["campaigns": [campaign]])
        return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
    }
}

/// Holds the campaign-bundle request until the test releases it; every other
/// request answers 200 at once.
final class HeldBundleNetworkClient: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<NetworkResponse, Error>?
    private var result: Result<NetworkResponse, Error>?

    func release(_ result: Result<NetworkResponse, Error>) {
        lock.lock()
        let waiter = self.waiter
        self.waiter = nil
        if waiter == nil { self.result = result }
        lock.unlock()
        waiter?.resume(with: result)
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        guard request.url.absoluteString.hasSuffix("/getCampaignBundle") else {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8), isSuccessful: true)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
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
