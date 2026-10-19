import Testing

@testable import DigiaEngage

/// Mirrors Flutter `campaign_router_test.dart`: gate order and the live-test
/// exception, with a fake screen so no orchestrator is involved. The pure
/// matrix is pinned in `SurfaceRuleTests`.
@MainActor
@Suite("DMC campaign router")
struct DMCCampaignRouterTests {
    private final class FakeSurfaces {
        var current: [SurfaceOccupant]
        var superseded: [SurfaceOccupant] = []
        var started: CampaignRequest?

        init(_ occupants: [SurfaceOccupant]) { current = occupants }

        func supersede(_ occupant: SurfaceOccupant) {
            if !superseded.contains(occupant) { superseded.append(occupant) }
            current.removeAll { $0 == occupant }
        }

        func start(_ request: CampaignRequest) -> RoutingVerdict {
            started = request
            return .accepted(payload: request.payload, kind: .modal)
        }
    }

    private func router(
        _ surfaces: FakeSurfaces, screen: String? = nil, capped: Bool = false
    ) -> CampaignRouter {
        CampaignRouter(
            occupants: { surfaces.current },
            supersede: surfaces.supersede,
            start: surfaces.start,
            currentScreen: { screen },
            capReason: { _ in capped ? .maxTotal : nil })
    }

    private func request(
        _ driver: CampaignDriver, _ json: [String: Any], metadata: [String: String] = [:]
    ) throws -> CampaignRequest {
        let campaign = try #require(try CampaignModel.fromJson(json))
        return CampaignRequest(
            driver: driver, campaign: campaign,
            payload: CEPTriggerPayload(
                cepCampaignId: "cep-\(campaign.campaignKey)", campaignKey: campaign.campaignKey,
                cepMetadata: metadata))
    }

    private func occupant(_ kind: SurfaceKind, key: String = "blocker", liveTest: Bool = false)
        -> SurfaceOccupant
    {
        SurfaceOccupant(
            kind: kind, campaignKey: key, cepCampaignId: liveTest ? "live-test-x" : "cep-\(key)",
            isLiveTest: liveTest, hasDisplayed: false)
    }

    private func liveTest() -> LiveTestDriver {
        let context = LiveTestContext(
            testInvocationId: "inv-x",
            reporter: LiveTestAckReporter(sender: MockNetworkClient()),
            onTerminal: {})
        return LiveTestDriver(context: context)
    }

    private func reason(_ verdict: RoutingVerdict) -> DropReason? {
        if case .dropped(let reason, _, _, _) = verdict { return reason }
        return nil
    }

    @Test("the screen gate drops before the frequency gate")
    func screenBeforeFrequency() throws {
        let surfaces = FakeSurfaces([])
        let verdict = router(surfaces, screen: "Home", capped: true)
            .route(try request(CepDriver(pluginId: "p"), nudgeJson("n", targetScreenNames: ["Detail"])))

        #expect(reason(verdict) == .screenNotTargeted)
        #expect(surfaces.started == nil)
    }

    @Test("the frequency gate drops before the surface gate")
    func frequencyBeforeSurface() throws {
        let surfaces = FakeSurfaces([occupant(.nudge)])
        let verdict = router(surfaces, screen: "Home", capped: true)
            .route(try request(CepDriver(pluginId: "p"), nudgeJson("n")))

        #expect(reason(verdict) == .frequencyCapped)
        #expect(surfaces.superseded.isEmpty)
        #expect(surfaces.started == nil)
    }

    @Test("a live test skips the cap")
    func liveTestSkipsCap() throws {
        let surfaces = FakeSurfaces([])
        let verdict = router(surfaces, screen: "Home", capped: true)
            .route(try request(liveTest(), nudgeJson("n")))

        #expect(verdict.isAccepted)
        #expect(surfaces.started != nil)
    }

    @Test("a live test supersedes every blocking occupant and shows")
    func liveTestSupersedesAll() throws {
        let real = occupant(.nudge, key: "real")
        let test = occupant(.survey, key: "test", liveTest: true)
        let surfaces = FakeSurfaces([real, test])
        let verdict = router(surfaces, screen: "Home").route(try request(liveTest(), nudgeJson("n")))

        #expect(surfaces.superseded == [real, test])
        #expect(verdict.isAccepted)
    }

    @Test("a real campaign never displaces a live test")
    func realNeverDisplacesLiveTest() throws {
        let test = occupant(.nudge, key: "test", liveTest: true)
        let surfaces = FakeSurfaces([test])
        let verdict = router(surfaces, screen: "Home")
            .route(try request(CepDriver(pluginId: "p"), nudgeJson("n")))

        #expect(surfaces.superseded.isEmpty)
        #expect(reason(verdict) == .surfaceBusy)
    }

    @Test("the template gate drops an inline CleverTap custom template")
    func templateGateDropsInlineCustomTemplate() throws {
        let surfaces = FakeSurfaces([])
        let verdict = router(surfaces, screen: "Home").route(
            try request(
                CepDriver(pluginId: "p"), inlineJson("home_banner"),
                metadata: ["templateName": "DigiaTemplate"]))

        #expect(reason(verdict) == .invalidConfig)
    }
}
