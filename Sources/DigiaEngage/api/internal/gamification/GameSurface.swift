import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// How a game settles: against its CEP presentation, or against the rewards
/// page. Mirrors Android's `GameSettle`.
enum GameSettle {
    /// A CEP campaign: direct, inline or floating entry.
    case presentation(payload: CEPTriggerPayload, entry: GamificationEntryKind)
    /// The rewards widget: settles against the rewards page, not a CEP presentation.
    case rewards(chanceId: String)
}

/// The one open path for every game: direct, entry and rewards games.
///
/// It owns, in this order, for every open: the busy check, the rewards-only
/// SDK recheck, the skin cache-or-download, the user id check, the single
/// `GameOpenRequest` build, and the policy-wired handoff to
/// `GamePresenter.open`. Mirrors Android's `GameSurface`.
@MainActor
final class GameSurface {
    init(_ sdk: SDKInstance) { self.sdk = sdk }

    private unowned let sdk: SDKInstance

    /// Opens the game for `campaign` with the chance `chanceId`, settling by
    /// `settle`. Every former open path (direct, entry tap, rewards chance)
    /// funnels through here.
    func open(
        campaign: CampaignModel,
        config: GamificationConfig,
        chanceId: String,
        settle: GameSettle
    ) {
        let campaignKey = campaign.campaignKey
        // 1. One game owns the surface: a second open fails `busy` and never
        // overwrites the live game. `GamePresenter.open` re-checks this
        // as the backstop for a race between the check and the handoff.
        guard !GamePresenter.isBusy else {
            log.w("Game not opened — another game is already open", campaign: campaignKey)
            fail(settle: settle, campaign: campaign, reason: PlayDropReason.busy)
            return
        }
        // 2. SDK compatibility recheck, rewards only: a presentation was
        // checked at routing, so only the rewards widget rechecks here.
        if case .rewards = settle,
           let required = config.minSdkVersion,
           let newer = GamificationConfig.isNewer(required, than: DigiaSdkVersion.value), newer
        {
            log.w(
                "Game not opened — needs a newer SDK (min=\(required))",
                campaign: campaignKey)
            fail(
                settle: settle, campaign: campaign,
                reason: GamificationSurface.causeUnsupportedSDK)
            return
        }
        // 3. Skin cache hit opens at once, else download-then-show.
        if let file = sdk.gamification.skinFileCache.cachedFile(
            skinId: config.skinId, version: config.skinVersion)
        {
            openResolved(
                file, campaign: campaign, config: config,
                chanceId: chanceId, settle: settle)
            return
        }
        log.d(
            "Gamification skin cache miss — downloading before show "
                + "(skinId=\(config.skinId), skinVersion=\(config.skinVersion))",
            campaign: campaignKey
        )
        let cache = sdk.gamification.skinFileCache
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let file = try await cache.download(
                    bundleUrl: config.bundleUrl, skinId: config.skinId,
                    version: config.skinVersion)
                self.openResolved(
                    file, campaign: campaign, config: config,
                    chanceId: chanceId, settle: settle)
            } catch {
                log.w(
                    "Game not opened — skin download failed",
                    campaign: campaignKey, error: "\(error)")
                self.fail(
                    settle: settle, campaign: campaign, reason: "skin_unavailable")
            }
        }
    }

    /// Steps 4–6 for a resolved skin file: the user id check, the single
    /// request build, and the policy-wired handoff to `GamePresenter.open`.
    /// A missing network client after a grant is unreachable on iOS — the
    /// grant needed the same client — so only the user id is checked.
    private func openResolved(
        _ file: URL,
        campaign: CampaignModel,
        config: GamificationConfig,
        chanceId: String,
        settle: GameSettle
    ) {
        let campaignKey = campaign.campaignKey
        // 4. No user, no game.
        guard let userId = sdk.services?.identityManager.userId, !userId.isEmpty else {
            log.d("Game not opened — no user id", campaign: campaignKey)
            fail(settle: settle, campaign: campaign, reason: PlayDropReason.missingConfig)
            return
        }
        // 5–6. Build the request once and hand it to the presenter with the
        // settle policy's callbacks.
        GamePresenter.open(
            makeGameOpenRequest(
                file: file, chanceId: chanceId, config: config, campaign: campaign,
                payload: Self.payload(settle: settle, campaign: campaign),
                userId: userId, settle: settle))
    }

    /// Settles a game that never opened (steps 1–4): a direct game dismisses
    /// so its acceptance watchdog stands down, every other policy degrades
    /// to the reason-coded `game_open_failed` event — never a toast —
    /// and an entry's teaser stays.
    private func fail(settle: GameSettle, campaign: CampaignModel, reason: String) {
        switch settle {
        case .presentation(let payload, let entry):
            guard entry == .inlineTeaser || entry == .floating else {
                sdk.coordinator.handle(.dismissed(reason: .autoTimeout), payload: payload)
                return
            }
            sdk.events.toDigia(
                GameOpenFailedEvent(reason: reason, denyReason: nil),
                payload: payload)
        case .rewards(let chanceId):
            sdk.events.toDigia(
                GameOpenFailedEvent(reason: reason, denyReason: nil),
                payload: Self.rewardsPayload(chanceId: chanceId, campaign: campaign))
        }
    }

    /// The close policy: a direct game dismisses as before, an inline card
    /// stays, a game opened from a floating entry asks the backend `state`
    /// and keeps or hides the floater. Every presentation policy refreshes
    /// rewards only when the page is already loaded — a close must not pay
    /// for a fetch the app never asked for — while a rewards game always
    /// refreshes.
    private func closed(settle: GameSettle, campaign: CampaignModel) {
        switch settle {
        case .presentation(let payload, let entry):
            sdk.gamification.refreshRewardsIfLoaded()
            switch entry {
            case .inlineTeaser:
                refreshInlineEntryAfterClose(
                    campaignKey: campaign.campaignKey, payload: payload)
            case .direct, .unknown:
                sdk.coordinator.handle(.dismissed(reason: .userClose), payload: payload)
            case .floating:
                refreshFloatingEntryAfterClose(
                    campaignKey: campaign.campaignKey, payload: payload)
            }
        case .rewards:
            sdk.gamification.refreshRewards()
        }
    }

    /// The failure policy: a direct game dismisses so its acceptance
    /// watchdog stands down; every other policy degrades to the
    /// reason-coded `game_open_failed` event, never a toast.
    private func failed(settle: GameSettle, campaign: CampaignModel, failure: GameFailure) {
        switch settle {
        case .presentation(let payload, let entry):
            guard entry == .inlineTeaser || entry == .floating else {
                sdk.coordinator.handle(.dismissed(reason: .autoTimeout), payload: payload)
                return
            }
            log.w(
                "Game not opened (reason=\(failure.wireValue))",
                campaign: campaign.campaignKey)
            sdk.events.toDigia(
                GameOpenFailedEvent(reason: failure.wireValue, denyReason: nil),
                payload: payload)
        case .rewards(let chanceId):
            log.w(
                "Rewards game not opened (reason=\(failure.wireValue))",
                campaign: campaign.campaignKey)
            sdk.events.toDigia(
                GameOpenFailedEvent(reason: failure.wireValue, denyReason: nil),
                payload: Self.rewardsPayload(chanceId: chanceId, campaign: campaign))
        }
    }

    /// The impression policy: every entry kind emits Impressed once the
    /// game WebView is actually displayed. `toCep` marks the owning
    /// presentation displaying through the coordinator — the iOS equivalent
    /// of Android's `reportDisplaying(owner)` + `Impressed` pair. A rewards
    /// game has no presentation owner, so its signal no-ops on the
    /// coordinator.
    private func shown(settle: GameSettle, campaign: CampaignModel) {
        sdk.events.toCep(
            .impressed, payload: Self.payload(settle: settle, campaign: campaign))
    }

    private static func payload(settle: GameSettle, campaign: CampaignModel) -> CEPTriggerPayload {
        switch settle {
        case .presentation(let payload, _): return payload
        case .rewards(let chanceId): return rewardsPayload(chanceId: chanceId, campaign: campaign)
        }
    }

    /// The rewards widget has no CEP presentation, so it opens with a
    /// synthetic payload: `rewards:<chanceId>` — impressions dedup by
    /// `cepCampaignId`, so reusing the campaign id would swallow repeat plays.
    private static func rewardsPayload(
        chanceId: String, campaign: CampaignModel
    ) -> CEPTriggerPayload {
        CEPTriggerPayload(
            cepCampaignId: "rewards:\(chanceId)",
            campaignKey: campaign.campaignKey, cepMetadata: [:], variables: nil)
    }

    /// The one `GameOpenRequest` builder: shared by entries, direct opens and
    /// rewards chances. Only the settle closures differ.
    private func makeGameOpenRequest(
        file: URL,
        chanceId: String,
        config: GamificationConfig,
        campaign: CampaignModel,
        payload: CEPTriggerPayload,
        userId: String,
        settle: GameSettle
    ) -> GameOpenRequest {
        let campaignKey = campaign.campaignKey
        // The live-test invocation the trigger carried, if any: the grant was asked
        // with it, and both the skin's `state` call and the close-time `state` call
        // need it back so a draft campaign answers. Derived here — never stored —
        // so it cannot mismatch the grant.
        let openTestInvocationId: String?
        switch settle {
        case .presentation(let presentationPayload, _):
            openTestInvocationId = testInvocationIdOf(presentationPayload.cepCampaignId)
        case .rewards:
            openTestInvocationId = nil
        }
        return GameOpenRequest(
            campaignKey: campaignKey,
            campaignId: campaign.id,
            skinId: config.skinId,
            skinVersion: config.skinVersion,
            chanceId: chanceId,
            testInvocationId: openTestInvocationId,
            projectId: sdk.config?.apiKey ?? "",
            userId: userId,
            entryFile: file,
            bundleRoot: file.deletingLastPathComponent(),
            showMute: config.showMute,
            onClose: { [weak self] in self?.closed(settle: settle, campaign: campaign) },
            onFailure: { [weak self] failure in
                self?.failed(settle: settle, campaign: campaign, failure: failure)
            },
            onShown: { [weak self] in self?.shown(settle: settle, campaign: campaign) },
            payload: payload,
            values: config.values,
            slots: config.usesSlots ? config.slots : []
        )
    }

    /// Asks the backend `state` after a game opened from a floating entry
    /// closes, then keeps or hides the floater on the main thread. With no
    /// user the call is skipped and the floater hides.
    private func refreshFloatingEntryAfterClose(
        campaignKey: String, payload: CEPTriggerPayload
    ) {
        // Out of sight at once; the round-trip only decides whether it returns.
        if sdk.floaterStoryOrchestrator.state?.payload.cepCampaignId == payload.cepCampaignId {
            sdk.floaterStoryOrchestrator.hold(true)
        }
        refreshEntryAfterClose(campaignKey: campaignKey, payload: payload) { [weak self] in
            self?.hideFloatingEntry(campaignKey: campaignKey, payload: payload)
        } onKept: { [weak self] in
            self?.sdk.floaterStoryOrchestrator.hold(false)
        }
    }

    /// Hides a floating entry after its game closed: removes the stored
    /// chance, hides the entry for the rest of the session, and dismisses the
    /// floater — if it still shows this payload — as completed, never as a
    /// user close.
    private func hideFloatingEntry(campaignKey: String, payload: CEPTriggerPayload) {
        sdk.gamificationSurface.hideFloatingEntry(campaignKey: campaignKey)
        if sdk.floaterStoryOrchestrator.state?.payload.cepCampaignId == payload.cepCampaignId {
            sdk.floaterStoryOrchestrator.dismiss(.completed)
        }
    }

    /// Asks the backend `state` after a game opened from an inline entry
    /// closes, then keeps or hides the card — the same rule as floating. A
    /// failed call keeps the card with its stored chance; any other
    /// non-playable answer removes the stored chance and dismisses the card.
    /// Inline entries never join the session hide, which is floating-only.
    private func refreshInlineEntryAfterClose(
        campaignKey: String, payload: CEPTriggerPayload
    ) {
        refreshEntryAfterClose(campaignKey: campaignKey, payload: payload) { [weak self] in
            self?.hideInlineEntry(campaignKey: campaignKey, payload: payload)
        }
    }

    /// The one entry-close round-trip both entries share: with no user the
    /// entry hides at once, otherwise the backend `state` decides. A failed
    /// call keeps the stored chance; any other non-playable answer runs `hide`.
    private func refreshEntryAfterClose(
        campaignKey: String,
        payload: CEPTriggerPayload,
        hide: @MainActor @escaping () -> Void,
        onKept: @MainActor @escaping () -> Void = {}
    ) {
        guard let userId = sdk.services?.identityManager.userId, !userId.isEmpty else {
            log.d(
                "Gamification entry hidden after close — no user id",
                campaign: campaignKey)
            hide()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.sdk.gamification.gameOutcomeSource.state(
                campaignKey: campaignKey,
                testInvocationId: testInvocationIdOf(payload.cepCampaignId))
            switch PlaySession.decideAfterClose(result) {
            case .keep(let replacement):
                if let replacement {
                    self.sdk.gamificationSurface.chances[campaignKey] = replacement
                }
                log.d(
                    "Gamification entry kept after close (\(result))",
                    campaign: campaignKey)
                onKept()
            case .hide:
                log.d(
                    "Gamification entry hidden after close (\(result))",
                    campaign: campaignKey)
                hide()
            }
        }
    }

    /// Hides an inline entry after its game closed: removes the stored chance
    /// and dismisses the card — if it still shows this delivery — as cancelled,
    /// never as a user close.
    private func hideInlineEntry(campaignKey: String, payload: CEPTriggerPayload) {
        sdk.gamificationSurface.chances.removeValue(forKey: campaignKey)
        sdk.inlineSurface.dismiss(payload)
    }
}
