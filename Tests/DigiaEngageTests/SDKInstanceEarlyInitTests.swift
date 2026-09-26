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
        try await waitUntil(sdk, .ready)
    }

    private func waitUntil(_ sdk: SDKInstance, _ state: SDKState) async throws {
        for _ in 0..<200 where sdk.sdkState != state {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sdk.sdkState == state)
    }

    @Test("initialize() completes while the fetch is still pending")
    func completesBeforeFetch() async throws {
        let network = HeldBundleNetworkClient()
        let sdk = makeInstance(network: network)

        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        #expect(sdk.services != nil)
        #expect(sdk.sdkState == .initializing)
        #expect(sdk.campaignStore.isEmpty)
        network.release(.success(Self.bundle(campaignKey: "launch")))
        try await waitUntilReady(sdk)
    }

    @Test("initialize() waits for the fetch, capped at 2 s; the fetch continues past the cap")
    func initializeCappedAwait() async throws {
        // (a) A held fetch: returns at the cap, still initializing.
        let held = HeldBundleNetworkClient()
        let slow = makeInstance(network: held)
        var start = Date()
        try await slow.initialize(DigiaConfig(apiKey: "test_key"))
        var elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 1.9 && elapsed < 3.0)
        #expect(slow.sdkState == .initializing)
        held.release(.success(Self.bundle(campaignKey: "launch")))
        try await waitUntilReady(slow)

        // (b) A fetch that answers at ~100 ms: returns then, ready.
        let quick = HeldBundleNetworkClient()
        let fast = makeInstance(network: quick)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); quick.release(.success(Self.bundle(campaignKey: "launch"))) }
        start = Date()
        try await fast.initialize(DigiaConfig(apiKey: "test_key"))
        elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0)
        #expect(fast.sdkState == .ready)

        // (c) A fetch that fails at ~100 ms: returns then, failed, no throw.
        let broken = HeldBundleNetworkClient()
        let failing = makeInstance(network: broken)
        Task { try? await Task.sleep(nanoseconds: 100_000_000); broken.release(.failure(URLError(.notConnectedToInternet))) }
        start = Date()
        try await failing.initialize(DigiaConfig(apiKey: "test_key"))
        elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0)
        #expect(failing.sdkState == .failed)
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

    @Test("a fetch failure leaves the SDK failed, drops initialization_failed, and a second initialize() recovers")
    func fetchFailureThenRetry() async throws {
        let failing = HeldBundleNetworkClient()
        let sdk = makeInstance(network: failing)
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))

        failing.release(.failure(URLError(.notConnectedToInternet)))
        try await waitUntil(sdk, .failed)
        #expect(sdk.campaignStore.isEmpty)

        let afterFailure = deliver(sdk, "launch")
        #expect(afterFailure.isSettled)
        #expect(afterFailure.dropReason == .initializationFailed)
        #expect(afterFailure.isHoldReleased)

        // The retry runs the fetch again; this one answers.
        failing.reset()
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        #expect(sdk.sdkState == .initializing)
        failing.release(.success(Self.bundle(campaignKey: "launch")))
        try await waitUntilReady(sdk)
        #expect(!sdk.campaignStore.isEmpty)
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

    /// Forgets an answer already given, so the next bundle request is held again.
    func reset() {
        lock.lock()
        result = nil
        lock.unlock()
    }

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
