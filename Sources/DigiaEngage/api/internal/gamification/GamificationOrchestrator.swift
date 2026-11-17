import Combine
import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// Owns every gamification function and its state: the play decision, game
/// open (direct, entry, surface), skin caching and prefetch, rewards fetch
/// and rewards state, host-action execution for games, entry-close handling,
/// and skin event reporting.
///
/// `SDKInstance` keeps one `gamification` property and one-line delegations
/// for the public API (`openRewards`, `refreshRewards`, rewards state); the
/// rewards views and the game surfaces reach in for the rest. No behaviour
/// change: every function below ran on `SDKInstance` before.
@MainActor
final class GamificationOrchestrator: ObservableObject {
    private unowned let sdk: SDKInstance

    /// Gamification skin files, cached immutable by skin id + version.
    let skinFileCache: SkinFileCache
    /// Gamification backend calls (`grantChance`, `getRewards`). Wraps the same
    /// client so tests drive it through `MockNetworkClient` with no second seam.
    let gameOutcomeSource: any GameOutcomeSource
    /// The one PlaySession every gamification chance request goes through. A
    /// `var` so tests can inject a fake; built from the same outcome source.
    lazy var playSession: PlaySession = PlaySession(
        source: gameOutcomeSource,
        identity: { [weak sdk] in
            guard let services = sdk?.services else { return nil }
            return PlayIdentity(
                userId: services.identityManager.userId ?? "",
                userHash: services.identityManager.userHash,
                deviceId: services.identityManager.deviceId
            )
        }
    )

    /// The latest `getRewards` answer, driving the rewards page and widget.
    /// Nil until the first fetch; a failed fetch keeps the previous one.
    @Published private(set) var rewardsResponse: GameRewardsResponse?
    /// True while the first fetch is in flight (the page shows a spinner).
    @Published private(set) var rewardsLoading = false
    /// Campaigns from the latest `getRewards` that are paused or ended — and
    /// so not in the bundle. Keyed by campaign key.
    private var rewardsCampaigns: [String: CampaignModel] = [:]
    private var rewardsRefreshTask: Task<Void, Never>?

    init(sdk: SDKInstance) {
        self.sdk = sdk
        self.skinFileCache = SkinFileCache(networkClient: sdk.networkClient)
        self.gameOutcomeSource = HttpGameOutcomeSource(networkClient: sdk.networkClient)
    }

    /// Prefetches every gamification skin on campaign sync, so a later show
    /// usually hits the cache. Fire-and-forget: failures drop and retry at
    /// the next sync or grant.
    func prefetchGamificationSkins(_ campaigns: [CampaignModel]) {
        let skins = campaigns.compactMap(\.gamificationConfig).map {
            (bundleUrl: $0.bundleUrl, skinId: $0.skinId, version: $0.skinVersion)
        }
        guard !skins.isEmpty else { return }
        let cache = skinFileCache
        Task { await cache.prefetch(skins) }
    }

    /// `Action.openGame` from a gamification entry canvas: opens the game with
    /// the chance stored at the trigger. The adapter lives on the surface.
    func openGame(forPayload payload: CEPTriggerPayload) {
        sdk.gamificationSurface.openFromEntry(payload)
    }

    // MARK: - Rewards

    /// Fetches `getRewards` and stores it for the page and the widget. Calls
    /// coalesce while one is in flight; a failure logs and keeps the last
    /// response, so the page degrades to previous content (or the empty
    /// message) instead of failing. With no user there is nothing to fetch:
    /// any stale response is dropped so a previous user's rewards never linger.
    func refreshRewards() {
        guard rewardsRefreshTask == nil else { return }
        guard let userId = sdk.services?.identityManager.userId, !userId.isEmpty else {
            clearRewardsForUserChange()
            return
        }
        rewardsLoading = rewardsResponse == nil
        rewardsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.rewardsRefreshTask = nil; self.rewardsLoading = false }
            switch await self.gameOutcomeSource.getRewards() {
            case .success(let response):
                self.storeRewards(response)
            case .failure(let error):
                log.d("Rewards fetch failed (\(error))")
            }
        }
    }

    /// Refreshes only when rewards were fetched before — a game close must not
    /// pay for a fetch the app never asked for.
    func refreshRewardsIfLoaded() {
        guard rewardsResponse != nil else { return }
        refreshRewards()
    }

    private func storeRewards(_ response: GameRewardsResponse) {
        var campaigns: [String: CampaignModel] = [:]
        for raw in response.campaigns {
            guard let campaign = try? CampaignModel.fromJson(
                raw, designTokens: sdk.currentDesignTokens,
                devicePlatform: "ios", timeAnchor: sdk.currentTimeAnchor)
            else { continue }
            campaigns[campaign.campaignKey] = campaign
        }
        rewardsCampaigns = campaigns
        rewardsResponse = response
    }

    /// Drops the rewards state: a new user must never see the previous user's
    /// rewards, and a user-less fetch must not keep stale content around.
    func clearRewardsForUserChange() {
        rewardsRefreshTask?.cancel()
        rewardsRefreshTask = nil
        rewardsResponse = nil
        rewardsLoading = false
        rewardsCampaigns.removeAll()
    }

    /// Resets the rewards state for a test teardown.
    func resetForTesting() {
        rewardsRefreshTask?.cancel()
        rewardsRefreshTask = nil
        rewardsResponse = nil
        rewardsLoading = false
        rewardsCampaigns.removeAll()
    }

    /// The rewards page title for a chance's campaign: the bundle first, then
    /// the paused/ended campaigns the response carried.
    func rewardsCampaignTitle(for campaignKey: String) -> String? {
        sdk.campaignStore.find(campaignKey)?.gamificationConfig?.rewardsPageTitle
            ?? rewardsCampaigns[campaignKey]?.gamificationConfig?.rewardsPageTitle
    }

    /// Opens the native rewards page. The app calls this from its own button
    /// or menu — or maps its own deep link to it (see `Digia.openRewards`) —
    /// and the page refreshes on appear.
    func openRewards() {
        refreshRewards()
        GameRewardsPresenter.presentPage()
    }

    /// Follows the widget's tap action: opens one chance the way an entry
    /// does, or opens the rewards page.
    func handleRewardsWidgetTap() {
        guard let response = rewardsResponse else { refreshRewards(); return }
        switch GameRewardsResponse.widgetTap(chances: response.chances, widget: response.widget) {
        case .openChance(let chanceId):
            if let chance = response.chances.first(where: { $0.chanceId == chanceId }) {
                openGameForRewardsChance(chance)
            }
        case .openPage:
            openRewards()
        }
    }

    /// Opens the game for a rewards chance the same way an entry does, then
    /// dismisses the page (if open) and refreshes on close. The busy, SDK,
    /// skin and user checks live in `GameSurface`, which settles failures as
    /// the reason-coded `game_open_failed` event — never a toast.
    func openGameForRewardsChance(_ chance: GameRewardChance) {
        guard let campaign = sdk.campaignStore.find(chance.campaignId)
            ?? rewardsCampaigns[chance.campaignId],
            let config = campaign.gamificationConfig
        else { return }
        NotificationCenter.default.post(name: .digiaDismissRewardsPage, object: nil)
        sdk.gameSurface.open(
            campaign: campaign, config: config, chanceId: chance.chanceId,
            settle: .rewards(chanceId: chance.chanceId))
    }

    /// Opens a reward's CTA deep link through the host action executor.
    func openRewardDeepLink(_ url: String) {
        do {
            try sdk.hostActionExecutor.execute(.openDeeplink(url), campaignKey: nil)
        } catch {
            log.w("Rewards deep link failed: \(error)")
        }
    }

    // MARK: - Play

    /// The one adapter every gamification chance request goes through: builds
    /// the PlayRequest and maps the decision to side effects on the main
    /// thread. A trigger passes `direct` for the entry kind and its driver;
    /// a direct entry tap passes `direct: true` with no driver — a granted
    /// `show` answer opens, anything else settles as dropped. Internal: the
    /// gamification surface calls it after the routing gates.
    func requestGameChance(
        campaign: CampaignModel,
        config: GamificationConfig,
        payload: CEPTriggerPayload,
        direct: Bool,
        driver: CampaignDriver?
    ) {
        let key = campaign.campaignKey
        let triggerId = payload.cepCampaignId.trimmingCharacters(in: .whitespacesAndNewlines)
        let testInvocationId = testInvocationIdOf(payload.cepCampaignId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await self.playSession.request(
                PlayRequest(
                    campaignKey: key,
                    triggerId: triggerId,
                    testInvocationId: testInvocationId,
                    direct: direct,
                    isGameBusy: { GamePresenter.isBusy }
                ))
            self.applyPlayDecision(
                decision, campaign: campaign, config: config, payload: payload,
                driver: driver)
        }
    }

    /// Maps one PlaySession decision to side effects. `Open` opens the game;
    /// `ShowEntry` stores the chance and renders the entry; `Drop` shows
    /// nothing and settles the presentation as dropped, with the reason-coded
    /// `game_open_failed` event carrying it.
    private func applyPlayDecision(
        _ decision: PlayDecision,
        campaign: CampaignModel,
        config: GamificationConfig,
        payload: CEPTriggerPayload,
        driver: CampaignDriver?
    ) {
        let campaignKey = campaign.campaignKey
        let cepCampaignId = payload.cepCampaignId
        switch decision {
        case .open(let chance):
            log.d(
                "Gamification chance granted (chanceId=\(chance.chanceId), show=\(chance.show)) — opening",
                campaign: campaignKey
            )
            prefetchGamificationBundle(config, campaignKey: campaignKey)
            sdk.gameSurface.open(
                campaign: campaign, config: config, chanceId: chance.chanceId,
                settle: .presentation(payload: payload, entry: config.entryKind))
        case .showEntry(let chance):
            log.d(
                "Gamification chance granted (chanceId=\(chance.chanceId), show=\(chance.show)) — showing entry",
                campaign: campaignKey
            )
            prefetchGamificationBundle(config, campaignKey: campaignKey)
            guard let driver else {
                log.d("Gamification entry not shown — no driver", campaign: campaignKey)
                sdk.coordinator.drop(
                    payload, reason: .error,
                    detail: "gamification entry has no driver")
                return
            }
            sdk.gamificationSurface.showEntry(
                campaign: campaign, config: config, payload: payload,
                chance: chance, driver: driver)
        case .drop(let reason, let denyReason):
            let dropReason: DropReason
            let detail: String
            var deliveryDetail: [String: Any] = [:]
            switch reason {
            case PlayDropReason.denied:
                dropReason = .frequencyCapped
                detail = "chance not granted (\(denyReason ?? "unknown"))"
                if let denyReason {
                    deliveryDetail["deny_reason"] = denyReason
                }
            case PlayDropReason.notShown:
                dropReason = .frequencyCapped
                detail = "chance granted without show"
            case PlayDropReason.busy:
                dropReason = .surfaceBusy
                detail = "busy"
            default:
                dropReason = .error
                detail = reason
            }
            log.d("Gamification chance not granted (reason=\(reason))", campaign: campaignKey)
            sdk.liveTestContexts[cepCampaignId]?.reportFailed(DropReason.error, message: detail)
            sdk.events.toDigia(
                GameOpenFailedEvent(reason: reason, denyReason: denyReason),
                payload: payload)
            sdk.coordinator.drop(
                payload, reason: dropReason, detail: detail,
                deliveryDetail: deliveryDetail.isEmpty ? nil : deliveryDetail)
        }
    }

    /// Prefetches the skin bundle when a chance is granted, so the show that
    /// follows usually hits the cache.
    private func prefetchGamificationBundle(_ config: GamificationConfig, campaignKey: String) {
        log.d(
            "Gamification prefetch (skinId=\(config.skinId), skinVersion=\(config.skinVersion))",
            campaign: campaignKey
        )
        let cache = skinFileCache
        let skin = (bundleUrl: config.bundleUrl, skinId: config.skinId, version: config.skinVersion)
        Task { await cache.prefetch([skin]) }
    }

    /// Forwards one skin `event` to Digia analytics with the chance, skin,
    /// and skin-version identity attached. A live test's payload suppresses
    /// it, like every other analytics event.
    func reportGameSkinEvent(
        name: String,
        properties: [String: Any],
        payload: CEPTriggerPayload,
        skinId: String,
        skinVersion: Int,
        chanceId: String
    ) {
        sdk.events.toDigia(
            GameSkinEvent(
                name: name, skinId: skinId, skinVersion: skinVersion,
                chanceId: chanceId, props: properties),
            payload: payload)
    }
}
