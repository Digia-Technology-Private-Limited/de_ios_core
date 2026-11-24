import Foundation
import Testing

@testable import DigiaEngage

/// Guards the generic skin HTTP gate and transport mapping: the production
/// lines are `validatedPath`, `httpMethod`, and the status/throw mapping in
/// `send`.
@Suite("Game bridge http", .tags(.unit, .game))
struct GameHttpBridgeTests {
    @Test("allowlist accepts single segments and rejects the rest")
    func allowlist() {
        #expect(GameHttpBridge.validatedPath("play") == "play")
        #expect(GameHttpBridge.validatedPath("getRewards") == "getRewards")
        #expect(GameHttpBridge.validatedPath("A") == "A")
        // Guards the leading-letter check.
        #expect(GameHttpBridge.validatedPath("1play") == nil)
        #expect(GameHttpBridge.validatedPath("") == nil)
        // Guards the segment/length check: traversal, dots, long names.
        #expect(GameHttpBridge.validatedPath("a/b") == nil)
        #expect(GameHttpBridge.validatedPath("a.b") == nil)
        #expect(GameHttpBridge.validatedPath(String(repeating: "a", count: 65)) == nil)
        #expect(GameHttpBridge.validatedPath(String(repeating: "a", count: 64)) != nil)
        #expect(GameHttpBridge.validatedPath(nil) == nil)
    }

    @Test("grantChance is forbidden: a skin must not grant itself chances")
    func grantChanceForbidden() {
        // Guards the explicit forbidden-path check, not the allowlist shape.
        #expect(GameHttpBridge.validatedPath("grantChance") == nil)
    }

    @Test("HTTP 200 returns the status and body unchanged, refusals included")
    func rawBodyPassthrough() async {
        let envelope: [String: Any] = ["isSuccess": true, "data": ["response": ["refused": "busy"]]]
        let client = FakeBridgeNetworkClient(result: .success(status: 200, body: envelope))
        let body = GameHttpBridge.jsonData(["chanceId": "ch_1", "playId": "p_1"])
        let result = await GameHttpBridge.send(
            client: client, baseUrl: "https://app.digia.tech", headers: [:],
            method: "POST", path: "play", body: body)

        // Guards the success arm: no merging, no re-shaping.
        switch result {
        case .success(let success):
            #expect(success.status == 200)
            let data = success.body?["data"] as? [String: Any]
            let response = data?["response"] as? [String: Any]
            #expect(response?["refused"] as? String == "busy")
        case .failure(let failure):
            Issue.record("expected success, got \(failure.code)")
        }
        #expect(client.lastURL?.absoluteString.hasSuffix("/gamification/play") == true)
        #expect(client.lastMethod == .post)
        #expect(client.lastBody?["chanceId"] as? String == "ch_1")
    }

    @Test("4xx passes through with its body; 5xx is server, 3xx network")
    func statusMapping() async {
        for status in [400, 403, 404, 429] {
            let client = FakeBridgeNetworkClient(result: .success(status: status, body: ["reason": "r\(status)"]))
            let result = await GameHttpBridge.send(
                client: client, baseUrl: "https://app.digia.tech", headers: [:],
                method: "GET", path: "rewards", body: nil)
            // Guards the 4xx arm of the status range check.
            guard case .success(let success) = result else {
                Issue.record("expected passthrough for status \(status)")
                continue
            }
            #expect(success.status == status)
            #expect(success.body?["reason"] as? String == "r\(status)")
        }
        for (status, code) in [(500, GameBridgeError.server), (503, .server), (302, .network)] {
            let client = FakeBridgeNetworkClient(result: .success(status: status, body: [:]))
            let result = await GameHttpBridge.send(
                client: client, baseUrl: "https://app.digia.tech", headers: [:],
                method: "GET", path: "rewards", body: nil)
            guard case .failure(let failure) = result else {
                Issue.record("expected failure for status \(status)")
                continue
            }
            // Guards the `status >= 500` split, and that the status rides along
            // for game_http_failed.
            #expect(failure.code == code)
            #expect(failure.status == status)
        }
    }

    @Test("a lowercase method never reaches the network")
    func lowercaseMethodRejected() async {
        let client = FakeBridgeNetworkClient(result: .success(status: 200, body: ["isSuccess": true]))

        // Guards the exact match inside send: the session forwards the method
        // verbatim, and the gate one layer down rejects it before any call.
        let result = await GameHttpBridge.send(
            client: client, baseUrl: "https://app.digia.tech", headers: [:],
            method: "post", path: "play", body: nil)
        guard case .failure(let failure) = result else {
            Issue.record("expected failure for lowercase method")
            return
        }
        #expect(failure.code == .badRequest)
        #expect(client.lastURL == nil)
    }

    @Test("transport failures answer network, timeouts answer timeout")
    func transportMapping() async {
        let failing = FakeBridgeNetworkClient(result: .failure(URLError(.notConnectedToInternet)))
        let network = await GameHttpBridge.send(
            client: failing, baseUrl: "https://app.digia.tech", headers: [:],
            method: "POST", path: "play", body: nil)
        guard case .failure(let networkFailure) = network else {
            Issue.record("expected failure")
            return
        }
        #expect(networkFailure.code == .network)
        // Guards the nil status on transport failures: there is no status.
        #expect(networkFailure.status == nil)

        let timingOut = FakeBridgeNetworkClient(result: .failure(URLError(.timedOut)))
        let timeout = await GameHttpBridge.send(
            client: timingOut, baseUrl: "https://app.digia.tech", headers: [:],
            method: "POST", path: "play", body: nil)
        guard case .failure(let timeoutFailure) = timeout else {
            Issue.record("expected failure")
            return
        }
        // Guards the URLError.timedOut arm.
        #expect(timeoutFailure.code == .timeout)
        #expect(timeoutFailure.status == nil)
    }

    @Test("a timeout wrapped in another error still answers timeout")
    func wrappedTimeoutMapping() async {
        // Guards the cause-chain walk: only the wrapped URLError.timedOut
        // names a timeout, and the answer is still timeout. Breaks if send
        // stops consulting gameTransportIsTimeout.
        let wrapped = NSError(
            domain: "test", code: 1,
            userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        let wrapping = FakeBridgeNetworkClient(result: .failure(wrapped))
        let result = await GameHttpBridge.send(
            client: wrapping, baseUrl: "https://app.digia.tech", headers: [:],
            method: "POST", path: "play", body: nil)
        guard case .failure(let failure) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(failure.code == .timeout)
    }
}

/// Canned `NetworkClient` for the skin HTTP tests.
private final class FakeBridgeNetworkClient: NetworkClient, @unchecked Sendable {
    enum Result {
        case success(status: Int, body: [String: Any])
        case failure(Error)
    }

    private let result: Result
    private(set) var lastURL: URL?
    private(set) var lastMethod: HTTPMethod?
    private(set) var lastBody: [String: Any]?

    init(result: Result) {
        self.result = result
    }

    func execute(request: NetworkRequest) async throws -> NetworkResponse {
        lastURL = request.url
        lastMethod = request.method
        if let body = request.body {
            lastBody = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        }
        switch result {
        case .success(status: let status, body: let body):
            let data = try JSONSerialization.data(withJSONObject: body)
            return NetworkResponse(statusCode: status, headers: [:], body: data)
        case .failure(let error):
            throw error
        }
    }

    func executeMultipart(request: MultipartUploadRequest) async throws -> NetworkResponse {
        throw URLError(.unsupportedURL)
    }

    func openSseStream(request: NetworkRequest, handler: any SseStreamHandler) -> any CancellableSubscription {
        FatalSubscription()
    }

    private final class FatalSubscription: CancellableSubscription, @unchecked Sendable {
        func cancel() {}
    }
}
