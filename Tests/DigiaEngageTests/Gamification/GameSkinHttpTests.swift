import Foundation
import Testing

@testable import DigiaEngage

/// Guards the generic skin HTTP gate and transport mapping: the production
/// lines are `validatedPath`, `httpMethod`, and the status/throw mapping in
/// `send`.
@Suite("Game skin http", .tags(.unit, .game))
struct GameSkinHttpTests {
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

    @Test("only exact GET and POST exist")
    func methods() {
        #expect(GameHttpBridge.httpMethod("POST") == HTTPMethod.post)
        #expect(GameHttpBridge.httpMethod("GET") == HTTPMethod.get)
        // Guards the exact match: lowercase answers invalid, like Android's
        // GameHttpBridge.call — the session forwards the method verbatim.
        #expect(GameHttpBridge.httpMethod("get") == nil)
        #expect(GameHttpBridge.httpMethod("post") == nil)
        #expect(GameHttpBridge.httpMethod("PUT") == nil)
        #expect(GameHttpBridge.httpMethod(nil) == nil)
    }

    @Test("jsonData encodes objects")
    func jsonData() {
        let data = GameHttpBridge.jsonData(["chanceId": "ch_1"])
        #expect(data != nil)
        let decoded = try? JSONSerialization.jsonObject(with: data!) as? [String: Any]
        #expect(decoded?["chanceId"] as? String == "ch_1")
    }

    @Test("endpoint joins the gamification path")
    func endpoint() {
        #expect(GameHttpBridge.endpoint(baseUrl: "https://app.digia.tech", path: "play")?.absoluteString
            == "https://app.digia.tech/api/v1/engage/sdk/gamification/play")
    }

    @Test("HTTP 200 returns the raw envelope unchanged, refusals included")
    func rawEnvelopePassthrough() async {
        let envelope: [String: Any] = ["isSuccess": true, "data": ["response": ["refused": "busy"]]]
        let client = FakeSkinNetworkClient(result: .success(status: 200, body: envelope))
        let body = GameHttpBridge.jsonData(["chanceId": "ch_1", "playId": "p_1"])
        let result = await GameHttpBridge.send(
            client: client, baseUrl: "https://app.digia.tech", headers: [:],
            method: .post, path: "play", body: body)

        // Guards the success arm: no merging, no re-shaping.
        switch result {
        case .success(let returned):
            #expect(returned["isSuccess"] as? Bool == true)
            let data = returned["data"] as? [String: Any]
            let response = data?["response"] as? [String: Any]
            #expect(response?["refused"] as? String == "busy")
        case .failure(let code):
            Issue.record("expected success, got \(code)")
        }
        #expect(client.lastURL?.absoluteString.hasSuffix("/gamification/play") == true)
        #expect(client.lastMethod == .post)
        #expect(client.lastBody?["chanceId"] as? String == "ch_1")
    }

    @Test("non-2xx answers by status: 429 is quota, other 4xx invalid, rest network")
    func non200Mapping() async {
        for status in [400, 401, 403, 404] {
            let client = FakeSkinNetworkClient(result: .success(status: status, body: [:]))
            let result = await GameHttpBridge.send(
                client: client, baseUrl: "https://app.digia.tech", headers: [:],
                method: .get, path: "rewards", body: nil)
            guard case .failure(let code) = result else {
                Issue.record("expected failure for status \(status)")
                continue
            }
            // Guards the 4xx arm of the status mapping.
            #expect(code == .invalid)
        }

        let quota = FakeSkinNetworkClient(result: .success(status: 429, body: [:]))
        let quotaResult = await GameHttpBridge.send(
            client: quota, baseUrl: "https://app.digia.tech", headers: [:],
            method: .get, path: "rewards", body: nil)
        guard case .failure(let quotaCode) = quotaResult else {
            Issue.record("expected failure for status 429")
            return
        }
        // Guards the 429 arm of the status mapping.
        #expect(quotaCode == .quota)

        let server = FakeSkinNetworkClient(result: .success(status: 500, body: [:]))
        let serverResult = await GameHttpBridge.send(
            client: server, baseUrl: "https://app.digia.tech", headers: [:],
            method: .get, path: "rewards", body: nil)
        guard case .failure(let serverCode) = serverResult else {
            Issue.record("expected failure for status 500")
            return
        }
        // Guards the fallback arm: only 429 and 4xx map elsewhere.
        #expect(serverCode == .network)
    }

    @Test("transport failures answer network, timeouts answer timeout")
    func transportMapping() async {
        let failing = FakeSkinNetworkClient(result: .failure(URLError(.notConnectedToInternet)))
        let network = await GameHttpBridge.send(
            client: failing, baseUrl: "https://app.digia.tech", headers: [:],
            method: .post, path: "play", body: nil)
        guard case .failure(let networkCode) = network else {
            Issue.record("expected failure")
            return
        }
        #expect(networkCode == .network)

        let timingOut = FakeSkinNetworkClient(result: .failure(URLError(.timedOut)))
        let timeout = await GameHttpBridge.send(
            client: timingOut, baseUrl: "https://app.digia.tech", headers: [:],
            method: .post, path: "play", body: nil)
        guard case .failure(let timeoutCode) = timeout else {
            Issue.record("expected failure")
            return
        }
        // Guards the URLError.timedOut arm.
        #expect(timeoutCode == .timeout)
    }
}

/// Canned `NetworkClient` for the skin HTTP tests.
private final class FakeSkinNetworkClient: NetworkClient, @unchecked Sendable {
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
