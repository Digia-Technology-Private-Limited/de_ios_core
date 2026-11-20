import Foundation
import Testing

@testable import DigiaEngage

/// The SDK builds a game's chance events from the server's answer facts (the
/// server sends no events) and sends them to Digia analytics only. A test
/// invocation reports none. Every `/play` is a Clicked (`play`, then `play_again`)
/// unless the game opened from an inline or floating entry, whose tap was the
/// click; a Direct game's click also reaches the CEP; a CTA is not a click; every direct game close reaches the CEP.
/// Each test names the production line it guards. Mirrors Android's
/// `GameChanceEventsAndCepTest`.
@MainActor
@Suite("Game chance events and CEP", .tags(.unit, .gamification))
struct GameChanceEventsAndCepTests {
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

    private static func envelope(_ response: [String: Any]) -> [String: Any] {
        ["isSuccess": true, "data": ["response": response]]
    }

    private static func props(_ event: [String: Any]) -> [String: Any] {
        event["properties"] as? [String: Any] ?? [:]
    }

    private static let grantAnswer: [String: Any] = [
        "granted": true, "chanceId": "ch-1", "expiresAt": "2026-11-20T00:00:00Z", "show": true,
        "campaignId": "camp-uid-1", "holdout": ["group": "shown", "period": 3], "isNew": true,
    ]

    // Fails if a grant answer's facts stop becoming events: the
    // `events: grantEventsOf(...)` line in `HttpGameOutcomeSource.grantChance`, or
    // the `granted, isNew` gate in `grantEventsOf` (the repeat-answer case).
    @Test("a fresh grant reports Assigned and Granted to Digia only; a repeat and a test do not")
    func freshGrantReportsAssignedAndGrantedToDigiaOnly_repeatAndTestDoNot() async throws {
        let (sdk, recorder) = try await rig()
        let client = MockNetworkClient()
        let body = try JSONSerialization.data(withJSONObject: Self.envelope(Self.grantAnswer))
        client.enqueueResponse(statusCode: 200, body: String(decoding: body, as: UTF8.self))
        let session = PlaySession(
            source: HttpGameOutcomeSource(networkClient: client),
            identity: { PlayIdentity(userId: "u_123", userHash: nil, deviceId: nil) })

        let decision = await session.request(PlayRequest(
            campaignKey: "bill_pay_spin", triggerId: "msg-9", testInvocationId: nil,
            direct: true, isGameBusy: { false }))
        guard case .open = decision else {
            Issue.record("expected .open, got \(decision)")
            return
        }
        #expect(decision.chanceEvents == [
            .assigned(GamificationAssigned(group: "shown", period: .int(3))),
            .granted(ChanceGranted(
                chanceId: "ch-1", source: ChanceGranted.sourceTrigger, expiresAt: "2026-11-20T00:00:00Z")),
        ])
        sdk.events.forwardChanceEvents(decision.chanceEvents, payload: recorder.payload)

        let events = try await digiaEvents(sdk)
        #expect(named("Digia Gamification Assigned", in: events).count == 1)
        let granted = try #require(named("Digia Chance Granted", in: events).first)
        #expect(Self.props(granted)["source"] as? String == "trigger")
        #expect(recorder.signals.isEmpty)

        // The same chance answered again (no `isNew`) is not a new grant.
        var repeatAnswer = Self.grantAnswer
        repeatAnswer.removeValue(forKey: "isNew")
        #expect(grantEventsOf(repeatAnswer, granted: true, chanceId: "ch-1", testInvocationId: nil)
            == [.assigned(GamificationAssigned(group: "shown", period: .int(3)))])
        // A live test reports nothing at all.
        #expect(grantEventsOf(Self.grantAnswer, granted: true, chanceId: "ch-1", testInvocationId: "inv-1").isEmpty)
    }

    // Fails if the Denied gate loosens or tightens: the
    // `!granted, isNew, denyReason, campaignId` condition in `grantEventsOf`.
    @Test("Denied needs a fresh answer for a known campaign")
    func deniedNeedsAFreshAnswerForAKnownCampaign() {
        let denied: [String: Any] = [
            "granted": false, "show": false, "denyReason": "capReached", "cap": "day",
            "campaignId": "camp-uid-1", "isNew": true,
        ]

        #expect(grantEventsOf(denied, granted: false, chanceId: nil, testInvocationId: nil)
            == [.denied(ChanceDenied(reason: "capReached", cap: "day"))])
        var repeatAnswer = denied
        repeatAnswer.removeValue(forKey: "isNew")
        #expect(grantEventsOf(repeatAnswer, granted: false, chanceId: nil, testInvocationId: nil).isEmpty)
        var noCampaign = denied
        noCampaign.removeValue(forKey: "campaignId")
        #expect(grantEventsOf(noCampaign, granted: false, chanceId: nil, testInvocationId: nil).isEmpty)
    }

    // Fails if plays stop being numbered per window or reported from the answer:
    // the `stats.nextPlayNumber()` / `forwardChanceEvents(playEventsOf(...))` lines in
    // `makeGameOpenRequest`'s `onHttpAnswer`, the `isNew` gate in `playEventsOf`, or
    // the `playNumber == 1` click choice, or the `openedDirect` CEP click.
    @Test("plays report Clicked and Played per answer; a Direct click also reaches the CEP")
    func playsReportClickedAndPlayedPerAnswer_directClickReachesCep() async throws {
        let (sdk, recorder) = try await rig()
        let first = Self.envelope([
            "outcomeKey": "slot-2", "kind": "reward", "rewardId": "rw-1",
            "grant": ["grantId": "g-1", "value": ["amountMinor": 5000, "currency": "INR"]],
            "extraChance": ["chanceId": "ch-2", "expiresAt": "2026-11-21T00:00:00Z"],
            "isNew": true,
        ])
        let second = Self.envelope(["outcomeKey": "slot-0", "kind": "none", "fallback": true, "isNew": true])
        // A replayed answer for a play already made: clicked, but not a new play.
        let replay = Self.envelope(["outcomeKey": "slot-0", "kind": "none"])
        let request = try directOpenRequest(sdk, recorder: recorder)

        for answer in [first, second, replay] {
            request.onHttpAnswer?("play", ["chanceId": "ch-1"], answer)
        }

        let reported = try await digiaEvents(sdk).filter {
            ["Digia Experience Clicked", "Digia Game Played", "Digia Chance Granted"]
                .contains($0["event_name"] as? String)
        }
        let summary = reported.map { event -> String in
            let p = Self.props(event)
            switch event["event_name"] as? String {
            case "Digia Experience Clicked":
                return "Clicked \(p["element_id"] as? String ?? "-") \(p["chance_id"] as? String ?? "-")"
            case "Digia Game Played":
                return "Played #\((p["play_number"] as? NSNumber)?.intValue ?? 0) \(p["outcome_key"] as? String ?? "-")"
                    + " replay=\(p["is_replay"] as? Bool ?? false) fallback=\(p["fallback"] as? Bool ?? false)"
            default:
                return "Granted \(p["chance_id"] as? String ?? "-") \(p["source"] as? String ?? "-")"
            }
        }
        #expect(summary == [
            "Clicked play ch-1",
            "Played #1 slot-2 replay=false fallback=false",
            "Granted ch-2 extraPlay",
            "Clicked play_again ch-1",
            "Played #2 slot-0 replay=true fallback=true",
            "Clicked play_again ch-1",
        ])
        let played = Self.props(try #require(named("Digia Game Played", in: reported).first))
        #expect(played["grant_id"] as? String == "g-1")
        #expect((played["value_minor"] as? NSNumber)?.intValue == 5000)
        #expect(played["currency"] as? String == "INR")
        #expect(recorder.clickedElementIds == ["play", "play_again", "play_again"])
    }

    // Fails if a window double-counts or a CTA is not reported once: the
    // `guard !shown` in `onShown` and the Digia-only Clicked in `onCta` in
    // `makeGameOpenRequest`, or the `play_refused` omission in
    // `GameEvent.Dismissed.properties`.
    @Test("a window reports one Viewed and one Dismissed on the open chance")
    func windowReportsOneViewedAndOneDismissedOnTheOpenChance() async throws {
        let (sdk, recorder) = try await rig()
        let request = try directOpenRequest(sdk, recorder: recorder)

        request.onShown?()
        request.onShown?() // a recreated host re-runs the ready handshake
        request.onHttpAnswer?("play", ["chanceId": "ch-1"], Self.envelope(["outcomeKey": "slot-1"]))
        request.onCta?("copy", nil)
        request.onClose?("skin")

        let events = try await digiaEvents(sdk)
        #expect(named("Digia Experience Viewed", in: events).count == 1)
        #expect(named("Digia Experience Clicked", in: events).map {
            [Self.props($0)["element_id"] as? String, Self.props($0)["chance_id"] as? String]
        } == [["play", "ch-1"], ["copy", "ch-1"]])
        #expect(recorder.clickedElementIds == ["play"]) // a CTA never reaches the CEP
        let dismissed = named("Digia Experience Dismissed", in: events)
        #expect(dismissed.count == 1)
        let props = Self.props(try #require(dismissed.first))
        #expect(props["chance_id"] as? String == "ch-1")
        #expect((props["plays"] as? NSNumber)?.intValue == 1)
        #expect(props["play_refused"] == nil)
    }

    // Guards the direct-only check around `coordinator.handle(.dismissed(...))`
    // in `closed`: an inline game's CEP presentation is its teaser, which
    // stays, so its close goes to Digia only.
    @Test("closing an inline game does not dismiss its presentation to the CEP")
    func inlineGameCloseDoesNotDismissToCep() async throws {
        let (sdk, recorder) = try await rig()
        sdk.coordinator.handle(.impressed, payload: recorder.payload)
        let request = try directOpenRequest(sdk, recorder: recorder, entry: .inlineTeaser)

        request.onShown?()
        request.onClose?("skin")
        request.onClose?("user")

        #expect(recorder.dismissReason == nil)
        let dismissed = named("Digia Experience Dismissed", in: try await digiaEvents(sdk))
        #expect(dismissed.count == 2)
    }

    // Guards `closedBeforeShown` behind `guard shown` in `onClose`: a game
    // closed before it showed was never Viewed, so it is an open failure
    // (`closed_before_ready`) that drops its presentation, never a Dismissed;
    // a cancel was already settled by the coordinator and reports nothing.
    @Test("a direct game closed before it showed fails to open instead of dismissing")
    func directGameClosedBeforeShownFailsToOpen() async throws {
        let (sdk, recorder) = try await rig()
        let request = try directOpenRequest(sdk, recorder: recorder)

        request.onClose?("user")

        let events = try await digiaEvents(sdk)
        #expect(named("Digia Experience Dismissed", in: events).isEmpty)
        let failed = named("game_open_failed", in: events)
        #expect(failed.map { Self.props($0)["reason"] as? String } == ["closed_before_ready"])
        #expect(recorder.dropReason == .error)

        let (cancelSdk, cancelRecorder) = try await rig()
        try directOpenRequest(cancelSdk, recorder: cancelRecorder).onClose?(GamePresentation.cancelledReason)
        let cancelEvents = try await digiaEvents(cancelSdk)
        #expect(named("Digia Experience Dismissed", in: cancelEvents).isEmpty)
        #expect(named("game_open_failed", in: cancelEvents).isEmpty)
        #expect(!cancelRecorder.isSettled)
    }

    // Fails if the entry's tap is counted twice or a replay is not counted: the
    // `!openedFromEntry || playNumber > 1` gate around the play Clicked, and the
    // entry check in `shown` that sends the game's Viewed to Digia only.
    @Test("an entry-opened game sends a Digia-only Viewed, no first-play Clicked, one replay Clicked")
    func entryOpenedGameCountsOnlyThePlayAgainAsAClickAndViewsDigiaOnly() async throws {
        for entry in [GamificationEntryKind.inlineTeaser, .floating] {
            let (sdk, recorder) = try await rig()
            let request = try directOpenRequest(sdk, recorder: recorder, entry: entry)

            request.onShown?()
            request.onHttpAnswer?(
                "play", ["chanceId": "ch-1"], Self.envelope(["outcomeKey": "slot-1", "isNew": true]))

            let firstPlay = try await digiaEvents(sdk)
            #expect(named("Digia Experience Viewed", in: firstPlay).count == 1, "\(entry)")
            // The entry's CEP presentation is the entry, never the game.
            #expect(!recorder.displayed, "\(entry)")
            #expect(named("Digia Experience Clicked", in: firstPlay).isEmpty, "\(entry)")
            #expect(named("Digia Game Played", in: firstPlay).count == 1, "\(entry)")

            request.onHttpAnswer?(
                "play", ["chanceId": "ch-2"], Self.envelope(["outcomeKey": "slot-1", "isNew": true]))

            let afterReplay = try await digiaEvents(sdk)
            #expect(named("Digia Experience Clicked", in: afterReplay).count == 1, "\(entry)")
            // The entry's slot is already released: plays never reach the CEP.
            #expect(recorder.clickedElementIds.isEmpty, "\(entry)")
        }
    }
}
