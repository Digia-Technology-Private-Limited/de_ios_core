import Foundation
import Testing

@testable import DigiaEngage

/// The post-ready http watchdog: a `state`, `play` or `getRewards` bridge call
/// with no answer within 30 s closes the shown game through the normal close
/// path and reports `game_rewards_failed` + `game_open_failed` (`http_timeout`),
/// surfacing the existing retry affordances (the entry stays, a rewards game
/// refreshes). A late answer is dropped: no reply, no analytics, no second
/// close. Mirrors Android's `GameHttpWatchdogTest`.
@MainActor
@Suite("Game http watchdog", .tags(.unit, .gamification))
struct GameHttpWatchdogTests {
    /// A hanging skin `http` call, resumed by hand: a late answer the watchdog
    /// must ignore. The waiter suspends on a `Void` continuation and reads the
    /// stashed answer after, so no non-`Sendable` value crosses isolation.
    @MainActor
    final class AnswerGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var answer: Result<GameHttpBridge.Success, GameHttpBridge.Failure>?

        func waitForAnswer() async -> Result<GameHttpBridge.Success, GameHttpBridge.Failure> {
            await withCheckedContinuation { continuations.append($0) }
            return answer ?? .failure(GameHttpBridge.Failure(code: .network, status: nil))
        }

        func resume(
            with answer: Result<GameHttpBridge.Success, GameHttpBridge.Failure>
        ) {
            self.answer = answer
            let pending = continuations
            continuations = []
            for continuation in pending { continuation.resume() }
        }
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

    private static func props(_ event: [String: Any]) -> [String: Any] {
        event["properties"] as? [String: Any] ?? [:]
    }

    /// A game's open request with a real entry file behind it, so a
    /// `GamePresentation` can be built from it exactly as `GameSurface.open`
    /// builds it.
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
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.html")
        try "".write(to: file, atomically: true, encoding: .utf8)
        return sdk.gameSurface.makeGameOpenRequest(
            file: file, chanceId: "ch-1", config: config, campaign: campaign, payload: recorder.payload,
            userId: "u_123", settle: .presentation(payload: recorder.payload, entry: entry))
    }

    /// A presentation whose `http` calls hang at [gate] until the test resumes
    /// them, with a short watchdog delay. The request's `onHttpTimeout` is the
    /// surface wiring, so the close and the analytics run the production path.
    private func hungPresentation(
        request: GameOpenRequest, gate: AnswerGate, scripts: @escaping @MainActor (String) -> Void
    ) throws -> GamePresentation {
        let presentation = try #require(GamePresentation(request: request))
        presentation.httpWatchdogSeconds = 0.05
        presentation.httpSend = { _, _, _ in await gate.waitForAnswer() }
        presentation.bridge.onSend = scripts
        return presentation
    }

    private func httpMessage(id: String, path: String) -> String {
        #"{"id":"\#(id)","type":"http","payload":{"method":"POST","path":"\#(path)","body":{"chanceId":"ch-1"}}}"#
    }

    private static func readyMessage() -> String {
        #"{"type":"ready","payload":{"bridgeVersion":2}}"#
    }

    private static func playAnswer() -> [String: Any] {
        ["isSuccess": true, "data": ["response": [
            "outcomeKey": "slot-1", "kind": "reward", "isNew": true,
        ]]]
    }

    /// Decodes one `window.DigiaBridge.__receive(...)` script's message type and id.
    private func decoded(_ script: String) throws -> (type: String, id: String?) {
        let prefix = "window.DigiaBridge.__receive("
        #expect(script.hasPrefix(prefix))
        #expect(script.hasSuffix(")"))
        let start = script.index(script.startIndex, offsetBy: prefix.count)
        let literal = String(script[start...].dropLast())
        let literalData = try #require(literal.data(using: .utf8))
        let encoded = try JSONDecoder().decode(String.self, from: literalData)
        let messageData = try #require(encoded.data(using: .utf8))
        let message = try #require(
            JSONSerialization.jsonObject(with: messageData) as? [String: Any])
        return (message["type"] as? String ?? "", message["id"] as? String)
    }

    // Fails if the watchdog stops reporting a hung play: the
    // `request.onHttpTimeout?` call in `httpWatchdogFired`. Without it the
    // frozen game never closes and neither `game_rewards_failed` nor
    // `game_open_failed` fires.
    @Test("a play with no answer closes the shown game and reports both events")
    func playHangClosesShownGame() async throws {
        let (sdk, recorder) = try await rig()
        let request = try directOpenRequest(sdk, recorder: recorder)
        let gate = AnswerGate()
        var scripts: [String] = []
        let presentation = try hungPresentation(request: request, gate: gate) { scripts.append($0) }
        presentation.receive(Self.readyMessage())
        presentation.receive(httpMessage(id: "p1", path: "play"))
        try? await Task.sleep(nanoseconds: 300_000_000)

        let reported = try await digiaEvents(sdk)
        let rewardsFailed = try #require(named("game_rewards_failed", in: reported).first)
        #expect(Self.props(rewardsFailed)["op"] as? String == "play")
        #expect(Self.props(rewardsFailed)["code"] as? String == "timeout")
        let openFailed = try #require(named("game_open_failed", in: reported).first)
        #expect(Self.props(openFailed)["reason"] as? String == "http_timeout")
        #expect(Self.props(openFailed)["stage"] as? String == "ready")
        #expect(Self.props(openFailed)["chance_id"] as? String == "ch-1")
        #expect(presentation.isClosing)
        // The normal close path: a Dismissed with the timeout reason, and the
        // direct CEP presentation ends as cancelled like any shown failure.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let closed = try await digiaEvents(sdk)
        #expect(named("Digia Experience Dismissed", in: closed).map {
            Self.props($0)["dismiss_reason"] as? String
        } == ["http_timeout"])
        #expect(recorder.dismissReason == .cancelled)

        // A late answer is dropped: no reply to the skin, no play analytics, no second close.
        let digiaCount = closed.count
        gate.resume(with: .success(GameHttpBridge.Success(status: 200, body: Self.playAnswer())))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let replies = try scripts.map(decoded)
        #expect(!replies.contains { $0.type == "result" && $0.id == "p1" })
        let after = try await digiaEvents(sdk)
        #expect(after.count == digiaCount)
        #expect(named("Digia Experience Dismissed", in: after).count == 1)
        #expect(named("Digia Game Played", in: after).isEmpty)
        #expect(named("Digia Experience Clicked", in: after).isEmpty)
    }

    // Fails if hung `state` calls stop being watched: the `armHttpWatchdog`
    // call in `performHttp`. Without it the frozen entry game never closes,
    // and the close-time `state` the entry needs for its retry never runs.
    @Test("a state with no answer keeps the entry for a retry and ignores the late answer")
    func stateHangKeepsEntryForRetry() async throws {
        let (sdk, recorder) = try await rig()
        sdk.setUserId("u_123")
        let request = try directOpenRequest(sdk, recorder: recorder, entry: .floating)
        let gate = AnswerGate()
        var scripts: [String] = []
        let presentation = try hungPresentation(request: request, gate: gate) { scripts.append($0) }
        presentation.receive(Self.readyMessage())
        presentation.receive(httpMessage(id: "s1", path: "state"))
        try? await Task.sleep(nanoseconds: 300_000_000)

        let reported = try await digiaEvents(sdk)
        // The watchdog's own report rides next to the close-time `state`
        // check's (which also fails while offline): op `state`, code `timeout`.
        let rewardOps = named("game_rewards_failed", in: reported).map {
            ((Self.props($0)["op"] as? String) ?? "", (Self.props($0)["code"] as? String) ?? "")
        }
        #expect(rewardOps.contains { $0 == ("state", "timeout") })
        #expect(named("game_open_failed", in: reported).map {
            Self.props($0)["reason"] as? String
        } == ["http_timeout"])
        // The entry game closed on the chance it was playing, and the
        // close-time `state` asks about that chance: with no answer it keeps
        // the entry, so the user retries by tapping.
        try? await Task.sleep(nanoseconds: 400_000_000)
        let client = try #require(sdk.networkClient as? MockNetworkClient)
        let stateCall = try #require(client.recordedRequests.last {
            $0.url.absoluteString == DigiaEndpoints.gamificationState
        })
        let bodyData = try #require(stateCall.body)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["chanceId"] as? String == "ch-1")

        // A late answer is dropped: no reply, no second close.
        let digiaCount = try await digiaEvents(sdk).count
        gate.resume(with: .success(GameHttpBridge.Success(status: 200, body: Self.playAnswer())))
        try? await Task.sleep(nanoseconds: 200_000_000)

        let replies = try scripts.map(decoded)
        #expect(!replies.contains { $0.type == "result" && $0.id == "s1" })
        #expect(try await digiaEvents(sdk).count == digiaCount)
        #expect(named("Digia Experience Dismissed", in: try await digiaEvents(sdk)).count == 1)
    }
}
