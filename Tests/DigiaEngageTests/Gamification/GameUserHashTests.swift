import Foundation
import Testing

@testable import DigiaEngage

/// S5 user verification: the hash follows the user id's lifecycle and travels
/// as `X-Digia-User-Hash` on every request. Guards the `IdentityManager` hash
/// storage, the `CurrentSessionRef` header mapping, and the `grantChance`
/// body field.
@Suite("Game user hash", .tags(.unit, .game))
struct GameUserHashTests {
    private func identity() -> IdentityManager {
        IdentityManager(storage: InMemoryLocalStorage(), idGenerator: { "D1" })
    }

    private func headers(for identity: IdentityManager?) -> [String: String] {
        let ref = CurrentSessionRef()
        ref.set(nil, identity: identity, requestHeaders: ["X-Digia-Project-Id": "p"])
        return URLSessionNetworkClient(
            sessionIdProvider: { ref.sessionId },
            headerProvider: { ref.requestHeaders }
        ).assembleHeaders(for: [:])
    }

    @Test("the hash header travels with the user id and clears on logout")
    func hashHeaderLifecycle() {
        let identity = identity()
        identity.setUserId("asha", userHash: "h1")

        // Guards the header mapping: hash next to the id.
        var assembled = headers(for: identity)
        #expect(assembled["X-Digia-User-Id"] == "asha")
        #expect(assembled["X-Digia-User-Hash"] == "h1")

        identity.clearUserId()

        // Guards the logout clear: neither header survives.
        assembled = headers(for: identity)
        #expect(assembled["X-Digia-User-Id"] == nil)
        #expect(assembled["X-Digia-User-Hash"] == nil)
    }

    @Test("no user means no hash header")
    func noUserNoHash() {
        // Guards the pre-login state: nothing user-shaped is sent.
        let assembled = headers(for: identity())
        #expect(assembled["X-Digia-User-Id"] == nil)
        #expect(assembled["X-Digia-User-Hash"] == nil)
    }

    @Test("a hash-less setUserId for another user drops the stored hash")
    func plainSetClearsHash() {
        let identity = identity()
        identity.setUserId("asha", userHash: "h1")
        identity.setUserId("ravi")

        // Guards the rotation safety: one user's hash must never ride another user's call.
        #expect(headers(for: identity)["X-Digia-User-Hash"] == nil)
    }

    @Test("grantChance carries the hash in the body")
    func grantChanceBody() async throws {
        let client = MockNetworkClient()
        client.enqueueResponse(
            statusCode: 200,
            body: #"{"isSuccess":true,"data":{"response":{"granted":false}}}"#)
        let source = HttpGameOutcomeSource(networkClient: client)

        _ = await source.grantChance(GrantChanceRequest(
            campaignKey: "k", userId: "asha", userHash: "h1",
            triggerId: "t", showNow: true, testInvocationId: nil, deviceId: nil))

        // Guards the body field: the backend reads the user from it for now.
        let data = try #require(client.lastRequest?.body)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["userHash"] as? String == "h1")
    }
}
