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
    /// Campaigns from the latest `getRewards` that are paused or ended — and
    /// so not in the bundle. Keyed by campaign key.
    private var rewardsCampaigns: [String: CampaignModel] = [:]
    private var rewardsRefreshTask: Task<Void, Never>?

    /// In-flight skin prefetches. Stored so they die with the SDK instead of
    /// leaking on a never-cancelled scope: cancelled on user change and test
    /// reset, like Android's SDK-scoped prefetcher. Entries reap themselves
    /// when their prefetch lands, so the map never grows.
    private var prefetchTasks: [UUID: Task<Void, Never>] = [:]

    init(sdk: SDKInstance) {
        self.sdk = sdk
        self.skinFileCache = SkinFileCache(networkClient: sdk.networkClient)
        self.gameOutcomeSource = HttpGameOutcomeSource(networkClient: sdk.networkClient)
    }

    /// Prefetches every gamification skin on campaign sync, so a later show
    /// usually hits the cache. Fire-and-forget: failures drop and retry at
    /// the next sync or grant. Detached, so the cache's disk stat never runs
    /// on the caller's thread — never the main actor. The handle is
    /// SDK-owned: cancelled on user change and test reset, like Android's
    /// SDK-scoped prefetcher.
    func prefetchGamificationSkins(_ campaigns: [CampaignModel]) {
        let skins = campaigns.compactMap(\.gamificationConfig).map {
            (bundleUrl: $0.bundleUrl, skinId: $0.skinId, version: $0.skinVersion)
        }
        guard !skins.isEmpty else { return }
        launchPrefetch(skins)
    }

    /// `Action.openGame` from a gamification entry canvas: opens the game with
    /// the chance stored at the trigger. The adapter lives on the surface.
    /// `reportClick` false when the caller already sent the tap's CEP click.
    func openGame(forPayload payload: CEPTriggerPayload, reportClick: Bool = true) {
        sdk.gamificationSurface.openFromEntry(payload, reportClick: reportClick)
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
        rewardsRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = Date()
            defer { self.rewardsRefreshTask = nil }
            switch await self.gameOutcomeSource.getRewards() {
            case .success(let response):
                self.storeRewards(response)
            case .failure(let error):
                log.d("Rewards fetch failed (\(error))")
                let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                SDKInstance.shared.events.toDigia(
                    GameRewardsFailedEvent(
                        health: GameHealthContext(
                            campaignId: "", skinId: "", skinVersion: 0,
                            entry: "rewards"),
                        op: "rewards", code: error.rewardsCode,
                        status: error.rewardsStatus,
                        durationMs: durationMs),
                    payload: CEPTriggerPayload(
                        cepCampaignId: "rewards:refresh", campaignKey: "",
                        cepMetadata: [:], variables: nil))
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
    /// In-flight prefetches die here too: they retain the old network client.
    func clearRewardsForUserChange() {
        cancelPrefetches()
        rewardsRefreshTask?.cancel()
        rewardsRefreshTask = nil
        rewardsResponse = nil
        rewardsCampaigns.removeAll()
    }

    /// Resets the rewards state for a test teardown.
    func resetForTesting() {
        cancelPrefetches()
        rewardsRefreshTask?.cancel()
        rewardsRefreshTask = nil
        rewardsResponse = nil
        rewardsCampaigns.removeAll()
    }

    /// Opens the hosted rewards page full screen. The app calls this from its
    /// own button or menu — or maps its own deep link to it (see
    /// `Digia.openRewards`). The page shows its loading view while the rewards
    /// refresh, which also gives the SDK the campaign designs it needs to open
    /// games from the page.
    func openRewards() {
        RewardsPageViewController.present { [weak self] in
            guard let self else { return RewardsPageURL.resolve(pageUrl: nil, environment: .production) }
            return await self.rewardsPageURL()
        }
    }

    /// Longest the page waits for the rewards refresh before using the cached
    /// `page.url`, or the environment default.
    static let pageURLWaitSeconds = 4.0

    /// Refreshes the rewards (waiting at most `pageURLWaitSeconds`), then
    /// resolves the page address: the backend's `page.url`, else the default
    /// for the environment.
    func rewardsPageURL() async -> URL {
        refreshRewards()
        if let refresh = rewardsRefreshTask {
            let race = FirstOf()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                race.continuation = continuation
                Task { @MainActor in await refresh.value; race.finish() }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(Self.pageURLWaitSeconds * 1_000_000_000))
                    race.finish()
                }
            }
        }
        return RewardsPageURL.resolve(
            pageUrl: rewardsResponse?.pageUrl,
            environment: sdk.config?.environment ?? .production)
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

    /// Opens the game for a rewards chance the same way an entry does. The
    /// rewards page, if open, stays underneath and refreshes on close. The busy, SDK,
    /// skin and user checks live in `GameSurface`, which settles failures as
    /// the reason-coded `game_open_failed` event — never a toast.
    ///
    /// `chance.campaignId` is the backend campaign id, not the key, so the
    /// lookup matches on `CampaignModel.id` first (the store and the rewards
    /// map are both keyed by campaign key). Android keys its rewards map by
    /// id and falls back to `findById`; this is the same lookup.
    func openGameForRewardsChance(_ chance: GameRewardChance) {
        guard let campaign = rewardsCampaigns.values.first(where: { $0.id == chance.campaignId })
            ?? sdk.campaignStore.all.first(where: { $0.id == chance.campaignId })
            ?? sdk.campaignStore.find(chance.campaignId)
            ?? rewardsCampaigns[chance.campaignId],
            let config = campaign.gamificationConfig
        else {
            log.w("Game skipped — unknown rewards campaign (campaignId=\(chance.campaignId))")
            return
        }
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
        let triggerId = PlaySession.triggerId(of: payload)
        let testInvocationId = testInvocationIdOf(payload.cepCampaignId)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let decision = await self.playSession.request(
                PlayRequest(
                    campaignKey: key,
                    triggerId: triggerId,
                    testInvocationId: testInvocationId,
                    direct: direct,
                    // A test send replaces an open game (GameSurface.open),
                    // so it is never dropped busy here.
                    isGameBusy: { !isLiveTestCepId(payload.cepCampaignId) && GamePresenter.isBusy }
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
        // The grant answer's chance events go to Digia analytics only, whatever
        // the decision (ADR 0002).
        sdk.events.forwardChanceEvents(decision.chanceEvents, payload: payload)
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
        case .drop(let reason, let denyReason, _):
            let dropReason: DropReason
            let detail: String
            // The play decision rides on the Dropped event, so a drop names
            // its cause (`not_shown`, `busy`, `denied`, ...) rather than only
            // the coarse drop reason.
            var deliveryDetail: [String: Any] = ["gamification_reason": reason]
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
            // Only a client failure is an open failure: denied, not-shown
            // and busy are expected drops, recorded on the delivery outcome.
            if dropReason == .error {
                sdk.events.toDigia(
                    GameOpenFailedEvent(
                        reason: reason, chanceId: "", entry: config.entryKind.rawValue,
                        skinId: config.skinId, skinVersion: config.skinVersion),
                    payload: payload)
            }
            sdk.coordinator.drop(
                payload, reason: dropReason, detail: detail,
                deliveryDetail: deliveryDetail)
        }
    }

    /// Prefetches the skin bundle when a chance is granted, so the show that
    /// follows usually hits the disk. Detached and SDK-owned, like the
    /// campaign-sync prefetch above.
    private func prefetchGamificationBundle(_ config: GamificationConfig, campaignKey: String) {
        log.d(
            "Gamification prefetch (skinId=\(config.skinId), skinVersion=\(config.skinVersion))",
            campaign: campaignKey
        )
        let skin = (bundleUrl: config.bundleUrl, skinId: config.skinId, version: config.skinVersion)
        launchPrefetch([skin])
    }

    /// Launches one prefetch off the main thread and ties it to the SDK
    /// lifecycle. The reaper awaits only the handle, never the SDK, and drops
    /// it when the prefetch lands.
    private func launchPrefetch(_ skins: [(bundleUrl: String, skinId: String, version: Int)]) {
        let cache = skinFileCache
        let id = UUID()
        let task = Task.detached { await cache.prefetch(skins) }
        prefetchTasks[id] = task
        Task { [weak self] in
            _ = await task.result
            await MainActor.run { self?.prefetchTasks.removeValue(forKey: id) }
        }
    }

    /// Cancels every in-flight prefetch without awaiting it.
    private func cancelPrefetches() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
    }
}

/// Resumes its continuation once, for whichever of two tasks finishes first.
@MainActor
private final class FirstOf {
    var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}
