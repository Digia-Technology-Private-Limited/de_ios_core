import Foundation
import Testing

@testable import DigiaEngage

/// A dashboard live test of an entry campaign shares its campaign key with the
/// published campaign. Its entry stays bound to the test campaign and its own
/// stored chance until a newer send replaces it, so a tap never opens the
/// published version and a close never touches the published chance.
@MainActor
@Suite("Gamification live-test entry", .tags(.unit, .gamification))
struct GamificationLiveTestEntryTests {
    private static let key = "bill_pay_spin"
    private static let testCep = liveTestCepId("inv-1")

    private func sdk() async throws -> SDKInstance {
        let suite = { UserDefaults(suiteName: "digia.test.\(UUID().uuidString)")! }
        let sdk = SDKInstance(
            defaults: suite(), legacyDefaults: suite(), makeNetworkClient: { _ in MockNetworkClient() })
        try await sdk.initialize(DigiaConfig(apiKey: "test_key"))
        return sdk
    }

    private static func config() throws -> GamificationConfig {
        try #require(GamificationConfig.fromJson([
            "skinId": "wheel", "skinVersion": 2,
            "bundleUrl": "https://cdn.example.com/skins/wheel/2/index.html",
            "templateType": "spinWheel", "config": [String: Any](),
            "entry": ["kind": "direct"],
        ]))
    }

    private static func campaign(id: String, _ config: GamificationConfig) -> CampaignModel {
        CampaignModel(
            id: id, campaignKey: key, campaignType: "gamification",
            config: .gamification(config), targetScreenNames: [])
    }

    private static func chance(_ id: String) -> GrantedChance {
        GrantedChance(chanceId: id, expiresAt: nil, show: true)
    }

    // Fails if a live-test payload falls through to the published campaign:
    // the `if isLiveTestCepId(payload.cepCampaignId)` branch in
    // `GamificationSurface.entryCampaign`. The test campaign leaves
    // `liveTestCampaigns` once the test reports shown.
    @Test("a tap after the test reported shown resolves the test campaign, not the published one")
    func tapAfterShownResolvesTheTestCampaign() async throws {
        let sdk = try await sdk()
        let config = try Self.config()
        sdk.campaignStore.populate([Self.campaign(id: "published", config)])
        let payload = CEPTriggerPayload(cepCampaignId: Self.testCep, campaignKey: Self.key, cepMetadata: [:])
        let controller = sdk.coordinator.open(payload, owner: "test")
        sdk.coordinator.accept(controller, kind: .floating)
        // Records the entry's campaign; the direct arm then drops without rendering.
        sdk.gamificationSurface.showEntry(
            campaign: Self.campaign(id: "test", config), config: config, payload: payload,
            chance: Self.chance("ch-test"), driver: CepDriver(pluginId: "test"))
        sdk.liveTestCampaigns.removeAll()

        #expect(sdk.gamificationSurface.entryCampaign(payload)?.id == "test")
    }

    // Fails if a test's chance is stored or hidden under the campaign key: the
    // `chances.removeValue(forKey: Self.entryKey(payload))` line in
    // `GamificationSurface.hideFloatingEntry` (`none`) and the
    // `chances[GamificationSurface.entryKey(payload)] = replacement` line in
    // `GameSurface.refreshEntryAfterClose` (`playable`).
    @Test(
        "closing a test's floating game updates only the test's chance",
        arguments: [
            (#"{"state":"none"}"#, nil as String?),
            (#"{"state":"playable","chanceId":"ch-next"}"#, "ch-next"),
        ])
    func closingATestGameTouchesOnlyTheTestChance(state: String, expected: String?) async throws {
        let sdk = try await sdk()
        let client = try #require(sdk.networkClient as? MockNetworkClient)
        client.enqueueResponse(
            url: DigiaEndpoints.gamificationState, statusCode: 200,
            body: #"{"isSuccess":true,"data":{"response":"# + state + "}}")
        sdk.setUserId("u_123")
        let payload = CEPTriggerPayload(cepCampaignId: Self.testCep, campaignKey: Self.key, cepMetadata: [:])
        let controller = sdk.coordinator.open(payload, owner: "test")
        sdk.coordinator.accept(controller, kind: .floating)
        let surface = sdk.gamificationSurface
        surface.chances[Self.key] = Self.chance("ch-live")
        surface.chances[GamificationSurface.entryKey(payload)] = Self.chance("ch-test")
        // The floating settle, not the config, routes the close; a floating
        // config would need a full teaser canvas.
        let config = try Self.config()
        let request = sdk.gameSurface.makeGameOpenRequest(
            file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("index.html"),
            chanceId: "ch-test", config: config, campaign: Self.campaign(id: "test", config),
            payload: payload, userId: "u_123", settle: .presentation(payload: payload, entry: .floating))

        request.onShown?()
        request.onClose?("skin")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(surface.chances[Self.key]?.chanceId == "ch-live")
        #expect(surface.chances[Self.testCep]?.chanceId == expected)
    }

    // Fails if the close-time `state` call for a live-test floater stops
    // carrying the test invocation (the `testInvocationIdOf(...)` argument in
    // `refreshEntryAfterClose`), asks about the stored chance instead of the
    // game's chance (the `chanceId` the closed game was playing), or stops
    // hiding on `played` (the `.hide` arm of `decideAfterClose`). Also fails if
    // the hide stops removing only the live-test chance or stops dismissing
    // the floater showing that payload (the `cepCampaignId ==` check guarding
    // `dismiss(.completed)`).
    @Test("a live-test floater whose chance is played dismisses after close")
    func liveTestFloaterPlayedDismissesAfterClose() async throws {
        let sdk = try await sdk()
        let client = try #require(sdk.networkClient as? MockNetworkClient)
        client.enqueueResponse(
            url: DigiaEndpoints.gamificationState, statusCode: 200,
            body: #"{"isSuccess":true,"data":{"response":{"state":"played","chanceId":"ch-test"}}}"#)
        sdk.setUserId("u_123")
        let payload = CEPTriggerPayload(cepCampaignId: Self.testCep, campaignKey: Self.key, cepMetadata: [:])
        let controller = sdk.coordinator.open(payload, owner: "test")
        sdk.coordinator.accept(controller, kind: .floating)
        let surface = sdk.gamificationSurface
        surface.chances[Self.key] = Self.chance("ch-live")
        // Deliberately stale: a re-trigger replaced the stored chance while
        // the game was open, so the close must ask about the game's chance.
        surface.chances[GamificationSurface.entryKey(payload)] = Self.chance("stale-chance")
        // The floater showing the live-test payload, like `showEntry` leaves it.
        #expect(sdk.floaterStoryOrchestrator.start(Self.floaterCampaign(), payload: payload, screenName: nil))
        // The floating settle, not the config, routes the close; a floating
        // config would need a full teaser canvas.
        let config = try Self.config()
        let request = sdk.gameSurface.makeGameOpenRequest(
            file: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("index.html"),
            chanceId: "ch-test", config: config, campaign: Self.campaign(id: "test", config),
            payload: payload, userId: "u_123", settle: .presentation(payload: payload, entry: .floating))

        request.onShown?()
        request.onClose?("skin")
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(surface.chances[Self.key]?.chanceId == "ch-live")
        #expect(surface.chances[Self.testCep] == nil)
        #expect(sdk.floaterStoryOrchestrator.state == nil)
        // The close-time `state` call carried the entry's campaign, the test
        // invocation and the played chance.
        let stateRequest = try #require(client.recordedRequests.last(where: {
            $0.url.absoluteString == DigiaEndpoints.gamificationState
        }))
        let body = try #require(JSONSerialization.jsonObject(
            with: stateRequest.body ?? Data()) as? [String: Any])
        #expect(body["campaignKey"] as? String == Self.key)
        #expect(body["chanceId"] as? String == "ch-test")
        #expect(body["testInvocationId"] as? String == "inv-1")
    }

    private static func floaterCampaign() -> CampaignModel {
        let canvas = CampaignCanvas(
            version: 2, width: 100, height: 100, background: .none, children: [])
        let window = FloaterStoryWindowConfig(
            widthFraction: 0.32, aspectRatio: 0.72, position: .bottomRight,
            margin: FloaterMargin(left: 16, top: 16, right: 16, bottom: 16),
            cornerRadiusDp: 16, borderWidthDp: 0, borderColor: nil, shadow: true,
            entryAnimation: FloaterEntryAnimation(type: .appear, from: .right, durationMs: 200),
            exitAnimation: FloaterExitAnimation(type: .none, to: .right, durationMs: 0))
        let config = FloaterStoryConfig(
            canvas: canvas, story: nil, designWidth: 100, window: window,
            controls: FloaterStoryControlsConfig(
                draggable: true, snapToCorner: true, showClose: true,
                iconSize: 24, margin: FloaterMargin(left: 8, top: 8, right: 8, bottom: 8)),
            behavior: FloaterStoryBehaviorConfig(
                onStoryEnd: .collapse, startExpanded: false,
                expandTransition: .sdkExpand, collapseTransition: .sdkCollapse,
                autoDismissAfterMs: nil, reshowOnReturn: false, pauseWhenObscured: false),
            variableSchemas: [])
        return CampaignModel(
            id: "floater-test", campaignKey: key, campaignType: "floater",
            config: .floaterStory(config), targetScreenNames: [])
    }
}
