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
}
