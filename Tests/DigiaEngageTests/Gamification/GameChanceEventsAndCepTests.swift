import Foundation
import Testing

@testable import DigiaEngage

/// Chance events the server returns go to Digia analytics only, never the CEP,
/// a play or a CTA never marks a CEP click, and every game close reaches the CEP. Each test names
/// the production line it guards. Mirrors Android's `GameChanceEventsAndCepTest`.
@MainActor
@Suite("Game chance events and CEP", .tags(.unit, .gamification))
struct GameChanceEventsAndCepTests {
    private static func chanceEvent(_ eventId: String) -> String {
        #"{"name":"Chance Granted","eventId":"\#(eventId)","occurredAt":"2026-11-19T10:00:00Z","campaignId":"camp-uid-1","properties":{"chanceId":"ch-1","count":2}}"#
    }

    /// An initialized SDK and a presentation opened on its own coordinator,
    /// recorded so every CEP mark it receives can be read back.
    private func rig() async throws -> (SDKInstance, PresentationRecorder) {
        let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
        let sdk = SDKInstance(
            defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() })
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        let controller = sdk.coordinator.open(
            CEPTriggerPayload(cepCampaignId: "msg-9", campaignKey: "bill_pay_spin", cepMetadata: [:]),
            owner: "test")
        sdk.coordinator.accept(controller, kind: .inline)
        return (sdk, PresentationRecorder(controller.presentation))
    }

    private func digiaEvents(_ sdk: SDKInstance) async throws -> [[String: Any]] {
        try? await Task.sleep(nanoseconds: 100_000_000)
        return await (try #require(sdk.services?.analyticsService)).queue.peek(maxCount: 100).map(\.payload)
    }

    private func named(_ name: String, in events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["event_name"] as? String == name }
    }

    /// A game's open request, as `GameSurface.open` builds it.
    private func directOpenRequest(
        _ sdk: SDKInstance, recorder: PresentationRecorder, entry: GamificationEntryKind = .direct
    ) throws -> GameOpenRequest {
        let config = try #require(GamificationConfig.fromJson([
            "skinId": "wheel", "skinVersion": 2,
            "bundleUrl": "https://cdn.example.com/skins/wheel/2/index.html",
            "templateType": "spinWheel", "config": [String: Any](),
        ]))
        let campaign = CampaignModel(
            id: "camp-uid-1", campaignKey: "bill_pay_spin", campaignType: "gamification",
            config: .gamification(config), targetScreenNames: [])
        return sdk.gameSurface.makeGameOpenRequest(
            file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("index.html"),
            chanceId: "ch-1", config: config, campaign: campaign, payload: recorder.payload,
            userId: "u_123", settle: .presentation(payload: recorder.payload, entry: entry))
    }

    // Guards `chanceEventsOf(response["events"], ...)` in `HttpGameOutcomeSource.grantChance`
    // and the `toDigia`-only body of `forwardChanceEvents`.
    @Test("chance events from grantChance go to Digia only")
    func chanceEventsFromGrantGoToDigiaOnly() async throws {
        let (sdk, recorder) = try await rig()
        let client = MockNetworkClient()
        client.enqueueResponse(
            statusCode: 200,
            body: #"{"isSuccess":true,"data":{"response":{"granted":true,"chanceId":"ch-1","show":true,"events":["#
                + Self.chanceEvent("evt-1") + #",{"name":"Broken"},"not an object"]}}}"#)
        let session = PlaySession(
            source: HttpGameOutcomeSource(networkClient: client),
            identity: { PlayIdentity(userId: "u_123", userHash: nil, deviceId: nil) })

        let decision = await session.request(PlayRequest(
            campaignKey: "bill_pay_spin", triggerId: "cep-1", testInvocationId: nil,
            direct: true, isGameBusy: { false }))
        guard case .open = decision else {
            Issue.record("expected .open, got \(decision)")
            return
        }
        sdk.events.forwardChanceEvents(decision.chanceEvents, payload: recorder.payload)

        let granted = named("Chance Granted", in: try await digiaEvents(sdk))
        #expect(granted.count == 1)
        let event = try #require(granted.first)
        #expect(event["event_id"] as? String == "evt-1")
        #expect(event["occurred_at"] as? String == "2026-11-19T10:00:00Z")
        #expect(event["campaign_id"] as? String == "camp-uid-1")
        #expect((event["properties"] as? [String: Any])?["chanceId"] as? String == "ch-1")
        #expect(recorder.signals.isEmpty)
    }

    // Guards the `forwardChanceEvents(chanceEventsOfAnswer(response, ...))` line in
    // `makeGameOpenRequest`'s `onHttpAnswer`.
    @Test("play answer events go to Digia only and the body reaches the skin unchanged")
    func playAnswerEventsGoToDigiaOnlyAndBodyReachesSkinUnchanged() async throws {
        let (sdk, recorder) = try await rig()
        let client = MockNetworkClient()
        client.enqueueResponse(
            statusCode: 200,
            body: #"{"isSuccess":true,"data":{"response":{"outcome":{"slot":2},"events":["#
                + Self.chanceEvent("evt-2") + "]}}}")

        let result = await GameHttpBridge.send(
            client: client, baseUrl: "https://app.digia.tech", headers: [:],
            method: "POST", path: "play", body: GameHttpBridge.jsonData(["chanceId": "ch-1"]))
        guard case .success(let success) = result else {
            Issue.record("expected an answered play, got \(result)")
            return
        }
        let response = (success.body?["data"] as? [String: Any])?["response"] as? [String: Any]
        #expect((response?["outcome"] as? [String: Any])?["slot"] as? Int == 2)
        #expect(((response?["events"] as? [Any])?.first as? [String: Any])?["eventId"] as? String == "evt-2")

        try directOpenRequest(sdk, recorder: recorder).onHttpAnswer?("play", nil, success.body)

        let granted = named("Chance Granted", in: try await digiaEvents(sdk))
        #expect(granted.map { $0["event_id"] as? String } == ["evt-2"])
        #expect(recorder.clickedElementIds.isEmpty)
    }

    // Guards the removed play click in `onHttpAnswer`, and the CTA path's removed CEP click.
    @Test("a play or a CTA never marks a CEP click")
    func playAndCtaNeverMarkCepClick() async throws {
        let (sdk, recorder) = try await rig()
        let request = try directOpenRequest(sdk, recorder: recorder)

        request.onHttpAnswer?("play", nil, nil)
        request.onHttpAnswer?("play", nil, nil)
        request.onCta?("copy")

        #expect(recorder.clickedElementIds.isEmpty)
        let clicked = named("Digia Experience Clicked", in: try await digiaEvents(sdk))
        #expect(clicked.map { ($0["properties"] as? [String: Any])?["element_id"] as? String } == ["copy"])
    }

    // Guards the `coordinator.handle(.dismissed(...))` line in `closed`, now run
    // for every entry kind: an inline game's close reaches the CEP once.
    @Test("closing an inline game dismisses its presentation to the CEP once")
    func inlineGameCloseDismissesToCepOnce() async throws {
        let (sdk, recorder) = try await rig()
        sdk.coordinator.handle(.impressed, payload: recorder.payload)
        let request = try directOpenRequest(sdk, recorder: recorder, entry: .inlineTeaser)

        request.onClose?("skin")
        request.onClose?("user")

        #expect(recorder.dismissReason == .userClose)
        let dismissed = named("Digia Experience Dismissed", in: try await digiaEvents(sdk))
        #expect(dismissed.count == 2)
    }
}
