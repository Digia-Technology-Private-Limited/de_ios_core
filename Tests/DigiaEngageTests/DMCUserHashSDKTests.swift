import Foundation
import Testing

@testable import DigiaEngage

/// Answers the campaign bundle with no campaigns and keeps each userContext body.
private final class UserContextRecorder: NetworkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [[String: Any]] = []

    var sent: [[String: Any]] { lock.withLock { bodies } }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        let url = request.url.absoluteString
        if url.hasSuffix("/getCampaignBundle") {
            let body = try JSONSerialization.data(withJSONObject: ["campaigns": [Any]()])
            return NetworkResponse(statusCode: 200, headers: [:], body: body, isSuccessful: true)
        }
        if url == DigiaEndpoints.userContext, let data = request.body,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.withLock { bodies.append(json) }
        }
        return NetworkResponse(statusCode: 200, headers: [:], body: Data("{}".utf8), isSuccessful: true)
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: [:], body: nil, isSuccessful: true)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        MockNetworkClient().openSseStream(request: request, handler: handler)
    }
}

/// `setUserId(_:userHash:)` through `SDKInstance`, not the manager alone: the
/// hash must reach the userContext request, or the backend withholds the
/// user's imported attributes.
@MainActor
@Suite("DMC userHash (SDKInstance)", .serialized)
struct DMCUserHashSDKTests {
    private let network = UserContextRecorder()

    private func makeSDK() -> SDKInstance {
        SDKInstance(
            defaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            legacyDefaults: UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")!,
            makeNetworkClient: { [network] _ in network })
    }

    private func initialize(_ sdk: SDKInstance) async throws {
        try await sdk.initialize(DigiaConfig(apiKey: "test-api-key"))
        for _ in 0..<300 where sdk.sdkState != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(sdk.sdkState == .ready)
    }

    /// The last body sent for `userId`, once one arrives.
    private func lastBody(for userId: String) async throws -> [String: Any]? {
        for _ in 0..<300 {
            if let body = network.sent.last(where: { $0["userId"] as? String == userId }) { return body }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    @Test("a userHash set after initialize is sent with the user")
    func setAfterInitialize() async throws {
        let sdk = makeSDK()
        try await initialize(sdk)

        sdk.setUserId("dana", userHash: "h1")

        let body = try #require(try await lastBody(for: "dana"))
        #expect(body["userHash"] as? String == "h1")
    }

    @Test("a userHash set before initialize is sent once the SDK is ready")
    func setBeforeInitialize() async throws {
        let sdk = makeSDK()
        sdk.setUserId("dana", userHash: "h1")

        try await initialize(sdk)

        let body = try #require(try await lastBody(for: "dana"))
        #expect(body["userHash"] as? String == "h1")
    }
}
