import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let gamificationSurfaceLog = DigiaLogger()

/// Gamification routing, in one place instead of spread across `SDKInstance`.
///
/// Like the surfaces in `CampaignSurfaces.swift` its constructor takes the SDK
/// instance and `start` routes one accepted campaign. It is a
/// `CampaignSurface` only so a cancelled presentation closes its game: a
/// direct entry parks no slot and floats no window, so there are no
/// occupants to report or supersede.
///
/// Every entry kind asks the PlaySession adapter for its chance on the
/// trigger. An inline or floating entry renders only when the answer comes
/// back granted with `show`; the granted chance is stored here, keyed by
/// campaign key, and a tap opens the game with it — never with a new grant.
@MainActor
final class GamificationSurface: CampaignSurface {
    /// Drop-cause strings, one set on both platforms.
    static let causeMissingConfig = "missing_config"
    static let causeUnsupportedOS = "unsupported_os"
    static let causeUnsupportedSDK = "unsupported_sdk"
    static let causeBridgeVersionUnsupported = "bridge_version_unsupported"
    static let causeUnsupportedEntry = "unsupported_entry"

    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    /// Whether this OS can show a game. A `var` so tests can override it;
    /// production reads the real floor (`GamePresenter` keeps its own check).
    var isOsSupported: () -> Bool = {
        if #available(iOS 17, *) { return true }
        return false
    }

    /// The granted chance stored at the trigger, keyed by `entryKey`. A tap
    /// opens the game with this, never with a new grant.
    var chances = [String: GrantedChance]()

    /// The campaign behind each shown entry, keyed by `entryKey`. A live
    /// test's campaign leaves `liveTestCampaigns` once the entry is shown, so
    /// a later tap or close resolves it from here.
    private(set) var entryCampaigns = [String: CampaignModel]()

    /// The key an entry's chance and campaign are stored under: a live test's
    /// own `cepCampaignId` (unique per send), else the campaign key. A test
    /// and the published campaign share a campaign key, so keying a test by it
    /// would let one overwrite or hide the other's chance.
    nonisolated static func entryKey(_ payload: CEPTriggerPayload) -> String {
        isLiveTestCepId(payload.cepCampaignId) ? payload.cepCampaignId : payload.campaignKey
    }

    /// The campaign for `payload`: the live-test or stored campaign, else the
    /// shown entry's. A live-test payload never falls through to the published
    /// campaign — a tap after the test reported shown opens the test version.
    func entryCampaign(_ payload: CEPTriggerPayload) -> CampaignModel? {
        if isLiveTestCepId(payload.cepCampaignId) {
            return sdk.liveTestCampaigns[payload.cepCampaignId]
                ?? entryCampaigns[payload.cepCampaignId]
        }
        return sdk.findCampaign(payload) ?? entryCampaigns[payload.campaignKey]
    }

    /// Routes an accepted gamification campaign: the OS and SDK gates, then
    /// the trigger/user/live-test gates, then the entry kind. An
    /// unknown kind drops and never opens a game. Every kind runs the
    /// PlaySession adapter with trigger AUTO and stays `accepted` while the
    /// answer is in flight; a granted answer with `show` opens a direct game
    /// or renders an inline/floating entry, anything else settles as dropped.
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
        guard config.bridgeSupported else {
            return request.invalidConfig(
                "gamification needs a newer SDK (bridgeVersion=\(config.bridgeVersion ?? 0))",
                cause: Self.causeBridgeVersionUnsupported)
        }
        let campaign = request.campaign
        let payload = request.payload
        let key = campaign.campaignKey
        let isLiveTest = request.driver.kind == .liveTest
        // The SDK never invents a trigger id: without one the server cannot
        // dedup repeats, so the trigger is dropped, not guessed. The explicit
        // id wins over the stamped payload id, as on Android.
        let triggerId = PlaySession.triggerId(of: payload, presentationId: request.presentationId)
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
        sdk.gamification.requestGameChance(
            campaign: campaign, config: config, payload: payload,
            direct: true, driver: request.driver, presentationId: request.presentationId)
        return .accepted(payload: payload, kind: .modal)
    }

    /// A non-direct trigger: hidden floaters drop first, then entries without
    /// a renderable canvas. Nothing renders here — the adapter runs with
    /// trigger AUTO and returns `accepted` at once; the granted `show` answer
    /// renders later through `showEntry`.
    private func startEntry(_ request: CampaignRequest, _ config: GamificationConfig) -> RoutingVerdict {
        let campaign = request.campaign
        let key = campaign.campaignKey
        switch config.entryKind {
        case .inlineTeaser:
            guard case .inline = config.entryCanvas else {
                return request.invalidConfig(
                    "gamification entry has no renderable canvas",
                    cause: Self.causeMissingConfig)
            }
        case .floating:
            guard campaign.floatingEntryCampaign != nil else {
                return request.invalidConfig(
                    "gamification entry has no renderable canvas",
                    cause: Self.causeMissingConfig)
            }
        case .direct, .unknown:
            return request.invalidConfig(
                "gamification entry has no renderable canvas",
                cause: Self.causeMissingConfig)
        }
        sdk.logVerbose(
            "routeByCampaignKey GAMIFICATION key='\(key)' "
                + "triggerId='\(PlaySession.triggerId(of: request.payload, presentationId: request.presentationId))'")
        sdk.gamification.requestGameChance(
            campaign: campaign, config: config, payload: request.payload,
            direct: false, driver: request.driver, presentationId: request.presentationId)
        return .accepted(
            payload: request.payload,
            kind: config.entryKind == .floating ? .floating : .inline)
    }

    /// Renders an entry for a granted `show` answer: stores the chance, then
    /// runs the platform's existing render calls. A render that drops (for
    /// example a floater losing `surface_busy`) removes the stored chance and
    /// settles the presentation with that same reason and detail — the inner
    /// start already reported its own drop to the driver, so nothing reports
    /// twice.
    func showEntry(
        campaign: CampaignModel,
        config: GamificationConfig,
        payload: CEPTriggerPayload,
        chance: GrantedChance,
        driver: CampaignDriver
    ) {
        let key = Self.entryKey(payload)
        chances[key] = chance
        entryCampaigns[key] = campaign
        let verdict: RoutingVerdict
        switch config.entryKind {
        case .inlineTeaser:
            guard case .inline(let cfg)? = config.entryCanvas else {
                chances.removeValue(forKey: key)
                sdk.coordinator.drop(
                    payload, reason: .error,
                    detail: "gamification entry has no renderable canvas")
                return
            }
            reportMissingVariables(cfg.variableSchemas, payload: payload)
            verdict = sdk.inlineSurface.startCanvas(
                CampaignRequest(driver: driver, campaign: campaign, payload: payload), cfg)
        case .floating:
            guard let floater = campaign.floatingEntryCampaign else {
                chances.removeValue(forKey: key)
                sdk.coordinator.drop(
                    payload, reason: .error,
                    detail: "gamification entry has no renderable canvas")
                return
            }
            verdict = sdk.floaterStorySurface.start(
                CampaignRequest(driver: driver, campaign: floater, payload: payload))
        case .direct, .unknown:
            chances.removeValue(forKey: key)
            gamificationSurfaceLog.d(
                "Gamification show entry for a non-entry campaign — dropping",
                campaign: campaign.campaignKey)
            sdk.coordinator.drop(
                payload, reason: .error, detail: "gamification entry has no renderable canvas")
            return
        }
        if case .dropped(
            let reason, let detail, _, _, let deliveryDetail) = verdict
        {
            chances.removeValue(forKey: key)
            gamificationSurfaceLog.d(
                "Dropped — entry render failed (\(detail ?? reason.value))",
                campaign: campaign.campaignKey)
            sdk.coordinator.drop(
                payload, reason: reason, detail: detail, deliveryDetail: deliveryDetail)
        }
    }

    /// `Action.openGame` from a gamification entry canvas, and the same tap
    /// from the story floater's window. Opens the game with the chance stored
    /// at the trigger — never with a new grantChance. A direct campaign has
    /// no entry canvas; a tap on one is ignored. `reportClick` is false when
    /// the tap already sent its CEP click (an inline primary CTA's
    /// `cta_primary`), so one tap is one CEP Clicked.
    func openFromEntry(_ payload: CEPTriggerPayload, reportClick: Bool = true) {
        guard let campaign = entryCampaign(payload),
              let config = campaign.gamificationConfig
        else {
            gamificationSurfaceLog.d(
                "Action.openGame ignored — not a gamification campaign",
                campaign: payload.campaignKey)
            return
        }
        if config.entryKind == .direct {
            gamificationSurfaceLog.d(
                "Action.openGame ignored — not inside a gamification entry",
                campaign: payload.campaignKey)
            return
        }
        let key = Self.entryKey(payload)
        switch PlaySession.decideTap(
            gameVisible: GamePresenter.isBusy,
            isLiveTest: isLiveTestCepId(payload.cepCampaignId),
            chance: chances[key])
        {
        case .fail(let reason):
            // Busy is not a failure, so it reports nothing.
            if reason != PlayDropReason.busy {
                sdk.events.toDigia(
                    GameOpenFailedEvent(
                        reason: reason, chanceId: chances[key]?.chanceId ?? "",
                        entry: config.entryKind.rawValue,
                        skinId: config.skinId, skinVersion: config.skinVersion,
                        warm: GamePrewarmer.warmKind(campaignKey: campaign.campaignKey),
                        tier: GamePrewarmer.deviceTier(),
                        msElapsed: 0, stage: GameOpenTiming.stageGrant),
                    payload: payload)
            }
            // The entry stays on screen, so its own presentation stays live.
            return
        case .open(let chance):
            // The tap is the entry's click, like Android.
            if reportClick { sdk.events.clicked(payload: payload, elementId: "entry") }
            sdk.gameSurface.open(
                campaign: campaign, config: config, chanceId: chance.chanceId,
                settle: .presentation(payload: payload, entry: config.entryKind))
        }
    }

    /// An entry's impression (inline render, floater shown): warms its game
    /// in the prewarm slot with the stored chance, built as the tap will
    /// build it. A no-op unless the prewarm config allows `game`.
    func prewarmEntry(_ payload: CEPTriggerPayload) {
        guard let campaign = entryCampaign(payload),
              let config = campaign.gamificationConfig,
              config.entryKind == .inlineTeaser || config.entryKind == .floating,
              let chance = chances[Self.entryKey(payload)]
        else { return }
        sdk.gameSurface.prewarm(
            campaign: campaign, config: config, chanceId: chance.chanceId,
            settle: .presentation(payload: payload, entry: config.entryKind), source: .entry)
    }

    var occupants: [SurfaceOccupant] { [] }

    func supersede(_: SurfaceOccupant) {}

    /// Closes the game, loading or visible, that `payload`'s presentation
    /// opened — the acceptance watchdog's teardown for a direct game.
    func dismiss(_ payload: CEPTriggerPayload) {
        guard let game = sdk.controller.activeGame ?? GamePresenter.loading,
              surfaceOwns(game.request.payload, payload: payload)
        else { return }
        game.dismiss(reason: GamePresentation.cancelledReason)
    }

    /// Forgets a floating entry's spent chance. A later trigger asks
    /// `grantChance` again, which decides whether the entry shows.
    func hideFloatingEntry(_ payload: CEPTriggerPayload) {
        chances.removeValue(forKey: Self.entryKey(payload))
        GamePrewarmer.discard(reason: "chance_gone", campaignKey: payload.campaignKey)
    }

    /// Clears the session entry state for a user change: the next user must
    /// not inherit stored chances. Called from the user
    /// change listener in `SDKInstance.initialize`.
    func clearForUserChange() {
        chances.removeAll()
        entryCampaigns.removeAll()
        GameChanceStateCache.shared.clearAll()
        GamePrewarmer.discard(reason: "chance_gone")
    }
}
