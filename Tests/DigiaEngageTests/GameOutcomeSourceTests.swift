import Foundation
import Testing

@testable import DigiaEngage

/// The `GameOutcomeSource` HTTP seam: envelope unwrap, typed results for every
/// `PlayRefusal`, and typed failures that never throw. Guards the unwrap path
/// (`data.response`), the refusal mapping, and the never-throws contract —
/// break any of those lines and these fail.
@Suite("Game outcome source", .tags(.unit, .network, .gamification))
struct GameOutcomeSourceTests {
    private func source(client: MockNetworkClient? = nil) -> (
        HttpGameOutcomeSource, MockNetworkClient
    ) {
        let client = client ?? MockNetworkClient()
        return (HttpGameOutcomeSource(networkClient: client), client)
    }

    private func envelope(_ response: String) -> String {
        #"{"isSuccess":true,"data":{"response":\#(response)}} "#
            .trimmingCharacters(in: .whitespaces)
    }

    private func body(of client: MockNetworkClient) throws -> [String: Any] {
        let data = try #require(client.lastRequest?.body)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func grantRequest(liveTest: Bool = false) -> GrantChanceRequest {
        GrantChanceRequest(
            campaignKey: "bill_pay_spin",
            userId: "u_123",
            userHash: nil,
            triggerId: "cep-1",
            showNow: liveTest ? nil : true,
            testInvocationId: liveTest ? "inv-1" : nil,
            deviceId: liveTest ? "device-1" : nil
        )
    }

    // MARK: - grantChance

    @Test("a grant unwraps the envelope and posts the CEP-mode fields")
    func grantChanceGranted() async throws {
        let (source, client) = source()
        client.enqueueResponse(
            statusCode: 200,
            body: envelope(
                #"{"granted":true,"chanceId":"ch_1","expiresAt":"2026-11-18T18:29:59Z","show":true}"#))

        let result = await source.grantChance(grantRequest())

        #expect(
            result
                == .granted(
                    GrantedChance(chanceId: "ch_1", expiresAt: "2026-11-18T18:29:59Z", show: true)))
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString.hasSuffix("/engage/sdk/gamification/grantChance"))
        #expect(request.method == .post)
        let sent = try body(of: client)
        #expect(sent["campaignKey"] as? String == "bill_pay_spin")
        #expect(sent["userId"] as? String == "u_123")
        #expect(sent["triggerId"] as? String == "cep-1")
        #expect(sent["showNow"] as? Bool == true)
        #expect(sent["testInvocationId"] == nil)
        #expect(request.headers["x-digia-device-id"] == nil)
    }

    @Test("a denial carries its reason; a holdout carries none")
    func grantChanceDenied() async {
        let (source, client) = source()
        client.enqueueResponse(
            statusCode: 200, body: envelope(#"{"granted":false,"show":false,"denyReason":"capReached"}"#))

        #expect(await source.grantChance(grantRequest()) == .denied(reason: "capReached"))

        client.reset()
        client.enqueueResponse(
            statusCode: 200, body: envelope(#"{"granted":false,"show":false}"#))

        #expect(await source.grantChance(grantRequest()) == .denied(reason: nil))
    }

    @Test("a live-test grant omits showNow and sends the device header")
    func grantChanceLiveTest() async throws {
        let (source, client) = source()
        client.enqueueResponse(
            statusCode: 200, body: envelope(#"{"granted":true,"chanceId":"ch_9","show":true}"#))

        let result = await source.grantChance(grantRequest(liveTest: true))

        #expect(result == .granted(GrantedChance(chanceId: "ch_9", expiresAt: nil, show: true)))
        let request = try #require(client.lastRequest)
        let sent = try body(of: client)
        #expect(sent["showNow"] == nil)
        #expect(sent["testInvocationId"] as? String == "inv-1")
        #expect(request.headers["x-digia-device-id"] == "device-1")
    }

    @Test("a grant without a chanceId is a failure, not a grant")
    func grantChanceMissingChanceId() async {
        let (source, client) = source()
        client.enqueueResponse(statusCode: 200, body: envelope(#"{"granted":true,"show":true}"#))

        let result = await source.grantChance(grantRequest())

        #expect(result == .failure(.invalidResponse("granted without chanceId")))
    }

    @Test("transport, HTTP and envelope faults are failures, never throws")
    func grantChanceFailures() async {
        let (source, client) = source()

        client.simulateTransportError(URLError(.notConnectedToInternet))
        let transport = await source.grantChance(grantRequest())
        guard case .failure(.transport) = transport else {
            Issue.record("expected a transport failure, got \(transport)")
            return
        }

        client.reset()
        client.enqueueResponse(statusCode: 500, body: "boom")
        #expect(await source.grantChance(grantRequest()) == .failure(.httpStatus(500)))

        client.reset()
        client.enqueueResponse(statusCode: 200, body: #"{"isSuccess":false,"data":{}}"#)
        #expect(
            await source.grantChance(grantRequest())
                == .failure(.invalidResponse("isSuccess is not true")))

        client.reset()
        client.enqueueResponse(statusCode: 200, body: #"{"isSuccess":true,"data":{}}"#)
        #expect(
            await source.grantChance(grantRequest())
                == .failure(.invalidResponse("missing data.response")))
    }

    // MARK: - play

    @Test("an outcome carries kind, reward type, grant and next chance")
    func playOutcome() async throws {
        let (source, client) = source()
        client.enqueueResponse(
            statusCode: 200,
            body: envelope(
                #"{"outcomeKey":"o_abc123","kind":"reward","rewardType":"coupon","grant":{"grantId":"gr_1"},"nextChance":{"chanceId":"ch_2"}}"#)
        )

        let result = await source.play(
            PlayRequest(chanceId: "ch_1", userId: "u_123", userHash: nil, playId: "p_1"))

        #expect(
            result
                == .outcome(
                    PlayOutcome(
                        outcomeKey: "o_abc123",
                        kind: .reward,
                        rewardType: .coupon,
                        grant: ["grantId": .string("gr_1")],
                        nextChance: ["chanceId": .string("ch_2")]
                    )))
        let request = try #require(client.lastRequest)
        #expect(request.url.absoluteString.hasSuffix("/engage/sdk/gamification/play"))
        let sent = try body(of: client)
        #expect(sent["chanceId"] as? String == "ch_1")
        #expect(sent["playId"] as? String == "p_1")
    }

    @Test("every refusal wire value maps to its case", arguments: [
        ("notVerified", GamificationPlayRefusal.notVerified),
        ("notFound", GamificationPlayRefusal.notFound),
        ("expired", GamificationPlayRefusal.expired),
        ("alreadyPlayed", GamificationPlayRefusal.alreadyPlayed),
        ("notPlayable", GamificationPlayRefusal.notPlayable),
        ("busy", GamificationPlayRefusal.busy),
    ])
    func playRefusals(wire: String, refusal: GamificationPlayRefusal) async {
        let (source, client) = source()
        client.enqueueResponse(statusCode: 200, body: envelope(#"{"refused":"\#(wire)"}"#))

        #expect(
            await source.play(
                PlayRequest(chanceId: "ch_1", userId: "u_123", userHash: nil, playId: "p_1"))
                == .refused(refusal))
    }

    @Test("an unknown refusal degrades to unavailable")
    func playUnknownRefusal() async {
        let (source, client) = source()
        client.enqueueResponse(statusCode: 200, body: envelope(#"{"refused":"frozen"}"#))

        #expect(
            await source.play(
                PlayRequest(chanceId: "ch_1", userId: "u_123", userHash: nil, playId: "p_1"))
                == .refused(.unavailable))
    }

    @Test("an unknown outcome kind is a failure")
    func playUnknownKind() async {
        let (source, client) = source()
        client.enqueueResponse(
            statusCode: 200, body: envelope(#"{"outcomeKey":"o_x","kind":"jackpot"}"#))

        #expect(
            await source.play(
                PlayRequest(chanceId: "ch_1", userId: "u_123", userHash: nil, playId: "p_1"))
                == .failure(.invalidResponse("unknown outcome kind")))
    }

    @Test("a play transport error is a failure, never a throw")
    func playTransportError() async {
        let (source, client) = source()
        client.simulateTransportError(URLError(.timedOut))

        let result = await source.play(
            PlayRequest(chanceId: "ch_1", userId: "u_123", userHash: nil, playId: "p_1"))

        guard case .failure(.transport) = result else {
            Issue.record("expected a transport failure, got \(result)")
            return
        }
    }
}
