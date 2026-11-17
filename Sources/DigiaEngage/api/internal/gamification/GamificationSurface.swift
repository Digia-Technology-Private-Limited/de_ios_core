import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let gamificationSurfaceLog = DigiaLogger()

/// Gamification routing, in one place instead of spread across `SDKInstance`.
///
/// Like the surfaces in `CampaignSurfaces.swift` its constructor takes the SDK
/// instance and `start` routes one accepted campaign — but it is not a
/// `CampaignSurface`: a direct entry parks no slot and floats no window, so
/// there are no occupants to report. It owns the campaign keys hidden this
/// session and asks the PlaySession adapter for a chance on a direct routing.
@MainActor
final class GamificationSurface {
    /// Drop-cause strings, one set on both platforms (D2).
    static let causeMissingConfig = "missing_config"
    static let causeUnsupportedOS = "unsupported_os"
    static let causeUnsupportedSDK = "unsupported_sdk"
    static let causeUnsupportedEntry = "unsupported_entry"

    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    /// Whether this OS can show a game. A `var` so tests can override it;
    /// production reads the real floor (`GamePresenter` keeps its own check).
    var isOsSupported: () -> Bool = {
        if #available(iOS 17, *) { return true }
        return false
    }

    /// Campaign keys whose entry the user closed with its X this app session.
    /// Memory only: the entry comes back on the next launch, and the chance
    /// stays unplayed either way.
    private(set) var hiddenEntries = Set<String>()

    /// Routes an accepted gamification campaign: the OS and SDK gates, then
    /// the trigger/user/live-test gates (D1, D2), then the entry kind. An
    /// unknown kind drops (D3) and never opens a game; a direct entry asks the
    /// PlaySession adapter for a chance and stays `accepted` while the answer
    /// is in flight; a teaser or floating entry renders its entry canvas and
    /// asks for the chance only when the user taps it (`openGame`).
    func start(_ request: CampaignRequest) -> RoutingVerdict {
        guard case .gamification(let config) = request.campaign.config else {
            assert(false, "GamificationSurface started without a gamification config")
            return request.invalidConfig(
                "campaign has no gamification config", cause: Self.causeMissingConfig)
        }
        guard isOsSupported() else {
            return request.invalidConfig(
                "gamification needs iOS 17 or later", cause: Self.causeUnsupportedOS)
        }
        if let required = config.minSdkVersion,
           let newer = GamificationConfig.isNewer(required, than: DigiaSdkVersion.value), newer
        {
            return request.invalidConfig(
                "gamification needs a newer SDK (min=\(required))", cause: Self.causeUnsupportedSDK)
        }
        let campaign = request.campaign
        let payload = request.payload
        let key = campaign.campaignKey
        let isLiveTest = request.driver.kind == .liveTest
        // The SDK never invents a trigger id: without one the server cannot
        // dedup repeats, so the trigger is dropped, not guessed.
        let triggerId = payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !triggerId.isEmpty else {
            return request.invalidConfig(
                "gamification skipped — no trigger id", cause: Self.causeMissingConfig)
        }
        guard sdk.services?.identityManager.userId?.isEmpty == false else {
            return request.invalidConfig(
                "gamification skipped — no user id", cause: Self.causeMissingConfig)
        }
        let testInvocationId = isLiveTest ? testInvocationIdOf(payload.cepCampaignId) : nil
        if isLiveTest, testInvocationId == nil {
            return request.invalidConfig(
                "gamification skipped — live test id missing", cause: Self.causeMissingConfig)
        }
        switch config.entryKind {
        case .unknown:
            return request.invalidConfig(
                "unknown gamification entry kind", cause: Self.causeUnsupportedEntry)
        case .inlineTeaser, .floating:
            return startEntry(request, config)
        case .direct:
            break
        }
        sdk.logVerbose("routeByCampaignKey GAMIFICATION key='\(key)' triggerId='\(triggerId)'")
        sdk.requestGameChance(campaign: campaign, config: config, payload: payload, trigger: .auto)
        return .accepted(payload: payload, kind: .modal)
    }

    /// Renders a non-direct entry: the campaign's entry canvas in its inline
    /// slot (teaser) or in the story floater (floating). No chance is requested
    /// here — the tap runs `Action.openGame`, which does that. A hidden entry
    /// drops first, for both kinds, before anything renders.
    private func startEntry(_ request: CampaignRequest, _ config: GamificationConfig) -> RoutingVerdict {
        let campaign = request.campaign
        let key = campaign.campaignKey
        if hiddenEntries.contains(key) {
            let detail = "gamification entry hidden for this session"
            gamificationSurfaceLog.d("Dropped — \(detail)", campaign: key)
            request.driver.policy.onDropped(DropReason.frequencyCapped, detail)
            return .dropped(
                reason: .frequencyCapped, detail: detail,
                deliveryDetail: ["cap_rule": "closed_for_session"])
        }
        switch config.entryCanvas {
        case .inline(let cfg)?:
            reportMissingVariables(cfg.variableSchemas, payload: request.payload)
            return sdk.inlineSurface.startCanvas(request, cfg)
        case .floating?:
            guard let floater = campaign.floatingEntryCampaign else { break }
            return sdk.floaterStorySurface.start(
                CampaignRequest(driver: request.driver, campaign: floater, payload: request.payload))
        case nil:
            break
        }
        return request.invalidConfig(
            "gamification entry has no renderable canvas", cause: Self.causeMissingConfig)
    }

    /// Hides a rendered entry whose chance can never open again, called by the
    /// PlaySession adapter on `PlayDecision.hideEntry`. Always records the key
    /// — for inline as well as floating — then removes the rendered entry: a
    /// floating entry dismisses the way its X does, an inline teaser is
    /// removed quietly. Direct campaigns show no entry, so there is nothing to
    /// remove.
    func hideEntry(campaign: CampaignModel, config: GamificationConfig, payload: CEPTriggerPayload) {
        hiddenEntries.insert(campaign.campaignKey)
        switch config.entryKind {
        case .floating:
            if sdk.floaterStoryOrchestrator.state?.payload.campaignKey == payload.campaignKey {
                sdk.floaterStoryOrchestrator.dismiss(.userClose)
            }
        case .inlineTeaser:
            if case .inline(let cfg) = config.entryCanvas,
               sdk.inlineController.getCampaign(cfg.slotKey) == payload
            {
                sdk.inlineController.dismissCampaign(cfg.slotKey)
            }
        case .direct, .unknown:
            break
        }
    }

    /// The floater's user close, wired to the orchestrator's `onUserClose`: a
    /// closed floater hides its entry for the rest of the session, but only
    /// when its campaign is a gamification one.
    func entryClosed(campaignKey: String) {
        let isGamification = sdk.campaignStore.find(campaignKey)?.gamificationConfig != nil
            || sdk.liveTestCampaigns.values.contains {
                $0.campaignKey == campaignKey && $0.gamificationConfig != nil
            }
        guard isGamification else { return }
        hiddenEntries.insert(campaignKey)
    }
}
