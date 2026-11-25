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
    /// funnels through here. `intentAt` (`MonotonicClock.nowSeconds()`) is when
    /// the open was asked for: a Direct trigger passes its trigger time, so
    /// the analytics timings run from it.
    func open(
        campaign: CampaignModel,
        config: GamificationConfig,
        chanceId: String,
        settle: GameSettle,
        intentAt: TimeInterval = MonotonicClock.nowSeconds()
    ) {
        let campaignKey = campaign.campaignKey
        let timing = GameOpenTiming(intentAt: intentAt)
        // 1. One game owns the surface: a second open fails `busy` and never
        // overwrites the live game. `GamePresenter.open` re-checks this
        // as the backstop for a race between the check and the handoff.
        guard !GamePresenter.isBusy else {
            // A dashboard test send replaces the game on screen; a real
            // campaign keeps busy-and-drop.
            if case .presentation(let payload, _) = settle, isLiveTestCepId(payload.cepCampaignId) {
                log.d("Test send replaces the open game", campaign: campaignKey)
                GamePresenter.replace(
                    open: { [weak self] in
                        self?.open(
                            campaign: campaign, config: config, chanceId: chanceId, settle: settle,
                            intentAt: intentAt)
                    },
                    drop: { [weak self] in
                        self?.fail(
                            settle: settle, campaign: campaign, config: config,
                            reason: PlayDropReason.busy, chanceId: chanceId, timing: timing)
                    })
                return
            }
            log.w("Game not opened — another game is already open", campaign: campaignKey)
            fail(
                settle: settle, campaign: campaign, config: config, reason: PlayDropReason.busy,
                chanceId: chanceId, timing: timing)
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
                settle: settle, campaign: campaign, config: config,
                reason: GamificationSurface.causeUnsupportedSDK, chanceId: chanceId, timing: timing)
            return
        }
        if case .rewards = settle, !config.bridgeSupported {
            log.w(
                "Game not opened — needs a newer SDK (bridgeVersion=\(config.bridgeVersion ?? 0))",
                campaign: campaignKey)
            fail(
                settle: settle, campaign: campaign, config: config,
                reason: GamificationSurface.causeBridgeVersionUnsupported, chanceId: chanceId,
                timing: timing)
            return
        }
        // 3. Skin cache hit opens at once, else download-then-show.
        if let file = sdk.gamification.skinFileCache.cachedFile(
            skinId: config.skinId, version: config.skinVersion)
        {
            openResolved(
                file, campaign: campaign, config: config,
                chanceId: chanceId, settle: settle, timing: timing)
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
                    chanceId: chanceId, settle: settle, timing: timing)
            } catch {
                log.w(
                    "Game not opened — skin download failed",
                    campaign: campaignKey, error: "\(error)")
                self.fail(
                    settle: settle, campaign: campaign, config: config, reason: "skin_unavailable",
                    chanceId: chanceId, timing: timing)
            }
        }
    }

    /// Steps 4–6 for a resolved skin file: the user id check, the single
    /// request build, and the policy-wired handoff to `GamePresenter.open`.
    /// A missing network client after a grant is unreachable on iOS — the
    /// grant needed the same client — so only the user id is checked. The
    /// storage identity is the user id, or the device id when the user id
    /// is missing — but the open still needs the user, like Android.
    private func openResolved(
        _ file: URL,
        campaign: CampaignModel,
        config: GamificationConfig,
        chanceId: String,
        settle: GameSettle,
        timing: GameOpenTiming
    ) {
        let campaignKey = campaign.campaignKey
        // A direct game whose presentation already settled — its acceptance
        // watchdog fired while the bundle loaded — must not open.
        if case .presentation(let payload, let entry) = settle, entry != .inlineTeaser, entry != .floating,
           payload.presentationId != nil, sdk.coordinator.ownerOf(payload) == nil {
            log.d("Game not opened — presentation already settled", campaign: campaignKey)
            // The open still failed: report it. Dropping the settled
            // presentation again is a no-op in the coordinator.
            fail(
                settle: settle, campaign: campaign, config: config,
                reason: Self.downloadTimeoutReason, chanceId: chanceId, timing: timing)
            return
        }
        // 4. No user, no game.
        guard let userId = sdk.services?.identityManager.userId, !userId.isEmpty else {
            log.d("Game not opened — no user id", campaign: campaignKey)
            fail(
                settle: settle, campaign: campaign, config: config,
                reason: PlayDropReason.missingConfig, chanceId: chanceId, timing: timing)
            return
        }
        // 5–6. Build the request once and hand it to the presenter with the
        // settle policy's callbacks.
        timing.stage = GameOpenTiming.stageLoad
        GamePresenter.open(
            makeGameOpenRequest(
                file: file, chanceId: chanceId, config: config, campaign: campaign,
                payload: Self.payload(settle: settle, campaign: campaign),
                userId: Self.storageIdentity(
                    userId: userId,
                    deviceId: sdk.services?.identityManager.deviceId),
                settle: settle, timing: timing))
    }

    /// Warms this game in the hidden prewarm slot (`GamePrewarmer`), only when
    /// its skin is already on disk and a user is set: the request is built
    /// exactly as the open will build it, so the open adopts it. Direct passes
    /// an empty `chanceId`; the grant's open swaps in the real request.
    func prewarm(
        campaign: CampaignModel,
        config: GamificationConfig,
        chanceId: String,
        settle: GameSettle,
        source: GamePrewarmSource
    ) {
        let prewarm = SDKInstance.shared.gamePrewarm
        guard prewarm.game,
              let file = sdk.gamification.skinFileCache.cachedFile(
            skinId: config.skinId, version: config.skinVersion),
            let userId = sdk.services?.identityManager.userId, !userId.isEmpty
        else { return }
        GamePrewarmer.warmGame(
            makeGameOpenRequest(
                file: file, chanceId: chanceId, config: config, campaign: campaign,
                payload: Self.payload(settle: settle, campaign: campaign),
                userId: Self.storageIdentity(
                    userId: userId,
                    deviceId: sdk.services?.identityManager.deviceId),
                settle: settle),
            source: source)
    }

    /// The bridge storage identity for one open: the user id, or the device
    /// id when there is no user — Android's `userId ?: deviceId`. Pure, so
    /// the shared case-table run pins the choice without a game.
    static func storageIdentity(userId: String?, deviceId: String?) -> String {
        guard let userId, !userId.isEmpty else { return deviceId ?? "" }
        return userId
    }

    /// The failure path for a game that never displayed. A client failure
    /// reports `game_open_failed`; busy is not a failure, so it reports
    /// nothing. A direct game also settles its presentation with the real
    /// reason — never a toast — and an entry's teaser stays. Matches Android.
    private func fail(
        settle: GameSettle, campaign: CampaignModel, config: GamificationConfig,
        reason: String, chanceId: String, timing: GameOpenTiming
    ) {
        log.w("Game not opened (reason=\(reason))", campaign: campaign.campaignKey)
        if reason != PlayDropReason.busy {
            let entry: String
            switch settle {
            case .presentation(_, let kind): entry = kind.rawValue
            case .rewards: entry = "rewards"
            }
            sdk.events.toDigia(
                GameOpenFailedEvent(
                    reason: reason, chanceId: chanceId, entry: entry,
                    skinId: config.skinId, skinVersion: config.skinVersion,
                    warm: timing.warm ?? GamePrewarmer.warmKind(campaignKey: campaign.campaignKey),
                    tier: GamePrewarmer.deviceTier(),
                    msElapsed: timing.msElapsed, stage: timing.stage),
                payload: Self.payload(settle: settle, campaign: campaign))
        }
        if case .presentation(let payload, let entry) = settle, entry != .inlineTeaser, entry != .floating {
            settleDirectFailure(payload: payload, reason: reason)
        }
    }

    /// The close policy: a direct game dismisses as before, an inline card
    /// stays, a game opened from a floating entry asks the backend `state`
    /// and keeps or hides the floater. Every close reports the funnel
    /// Dismissed to Digia; only a direct game sends a CEP Dismissed, since an
    /// inline or floating entry's CEP presentation is the entry, which stays
    /// on screen. Matches Android. Every presentation policy refreshes rewards only when
    /// the page is already loaded, while a rewards game always refreshes.
    /// `chanceId` is the chance the closed game was playing.
    private func closed(
        settle: GameSettle, campaign: CampaignModel, reason: String, chanceId: String,
        dismissed: GameEvent.Dismissed
    ) {
        switch settle {
        case .presentation(let payload, let entry):
            sdk.events.toDigia(dismissed, payload: payload)
            // Through the emitter, so a live test relays "dismissed" to the
            // dashboard too; for a real campaign the coordinator settles once,
            // so the CEP hears one Dismissed. A cancel comes from the
            // coordinator, which already settled and reported the presentation
            // to the CEP. Matches Android.
            if entry != .inlineTeaser, entry != .floating, reason != GamePresentation.cancelledReason {
                sdk.events.toCep(.dismissed(reason: Self.dismissReason(closeReason: reason)), payload: payload)
            }
            // A live test wins nothing real, so there is nothing to refresh — and the
            // refresh's failure event rides `rewards:refresh`, which is not a live-test
            // id and would escape live-test suppression. Matches Android.
            if testInvocationIdOf(payload.cepCampaignId) == nil {
                sdk.gamification.refreshRewardsIfLoaded()
            }
            switch entry {
            case .inlineTeaser:
                refreshInlineEntryAfterClose(
                    campaignKey: campaign.campaignKey, payload: payload, chanceId: chanceId)
            case .direct, .unknown:
                break
            case .floating:
                refreshFloatingEntryAfterClose(
                    campaignKey: campaign.campaignKey, payload: payload, chanceId: chanceId)
            }
        case .rewards(let chanceId):
            sdk.events.toDigia(
                dismissed, payload: Self.rewardsPayload(chanceId: chanceId, campaign: campaign))
            sdk.gamification.refreshRewards()
            NotificationCenter.default.post(name: .digiaRewardsGameClosed, object: nil)
        }
    }

    /// A game window that closed before it was shown was never Viewed, so it
    /// is never Dismissed. A close by the user, the skin, a CTA or a screen
    /// change is an open failure (`closed_before_ready`), which also drops a
    /// direct presentation. A cancel was settled by the coordinator, so it
    /// reports nothing; a superseded direct game only settles its
    /// presentation as superseded, since nothing else does. That goes to the
    /// coordinator, not the emitter: a superseded test send was already failed
    /// `superseded` by the router (SR46) and must not relay "dismissed".
    /// Matches Android.
    private func closedBeforeShown(
        settle: GameSettle, campaign: CampaignModel, config: GamificationConfig,
        reason: String, chanceId: String, timing: GameOpenTiming
    ) {
        switch reason {
        case GamePresentation.cancelledReason:
            return
        case "superseded":
            if case .presentation(let payload, let entry) = settle, entry != .inlineTeaser, entry != .floating {
                sdk.coordinator.handle(.dismissed(reason: .superseded), payload: payload)
            }
        default:
            fail(
                settle: settle, campaign: campaign, config: config,
                reason: GameFailureReason.closedBeforeReady.wireValue, chanceId: chanceId, timing: timing)
        }
    }

    /// Settles a direct game that did not open with the real reason so the
    /// CEP, the timeline and the live-test report see why. A presentation
    /// that already displayed can only be dismissed.
    private func settleDirectFailure(payload: CEPTriggerPayload, reason: String) {
        if sdk.coordinator.ownerOf(payload)?.state == .displaying {
            sdk.coordinator.handle(.dismissed(reason: .autoTimeout), payload: payload)
            return
        }
        let dropReason: DropReason
        switch reason {
        case PlayDropReason.busy: dropReason = .surfaceBusy
        case GameFailureReason.readyTimeout.wireValue, GameFailureReason.loadTimeout.wireValue,
             GameFailureReason.openTimeout.wireValue: dropReason = .timeout
        default: dropReason = .error
        }
        sdk.liveTestContexts[payload.cepCampaignId]?.reportFailed(dropReason, message: reason)
        sdk.coordinator.drop(
            payload, reason: dropReason, detail: reason,
            extras: dropReason == .timeout ? ["surface_kind": "gamification"] : nil)
    }

    /// The CEP reason for a direct game's close: the native close button and
    /// the skin's own `close` (and a web process death after the game
    /// showed) are the user's (as an authored Hide is on other
    /// campaigns; `completed` is kept for an experience that reached its end),
    /// a CTA handoff is a CTA, a host screen change is a screen exit,
    /// anything else is a cancel. Matches Android.
    static func dismissReason(closeReason: String) -> DismissReason {
        switch closeReason {
        case "user", "skin", "web_process_terminated": return .userClose
        case "cta": return .ctaAction
        case "superseded": return .superseded
        case "screen_exit": return .screenExit
        // A shown game whose skin call hung: the SDK withdrew it, like any
        // other shown failure on Android (which reports CANCELLED the same way).
        case GameFailureReason.httpTimeout.wireValue: return .cancelled
        default: return .cancelled
        }
    }

    /// The `dismiss_reason` analytics value for a game close: every known
    /// close reason passes through (`superseded` is a test send replacing
    /// the game; `web_process_terminated` is a web process death after the
    /// game showed; `back` and `timeout` are Android's and never reach iOS),
    /// anything unknown is the user's. Matches Android's
    /// `gameDismissReasonOf`.
    static func gameDismissReason(closeReason: String) -> String {
        switch closeReason {
        case "user", "back", "screen_exit", GamePresentation.cancelledReason, "skin", "cta", "failure",
             "superseded", "web_process_terminated", GameFailureReason.httpTimeout.wireValue:
            return closeReason
        default: return "user"
        }
    }

    /// The impression policy: the funnel Viewed goes to Digia for every
    /// settle once the game WebView is actually displayed. Only a direct game
    /// also tells the CEP: `toCep` marks the owning presentation displaying
    /// through the coordinator — the iOS equivalent of Android's
    /// `reportDisplaying(owner)` + `Impressed` pair. An entry's CEP
    /// presentation is the entry, already Impressed when it rendered, and a
    /// rewards game's synthetic payload owns no presentation.
    private func shown(settle: GameSettle, campaign: CampaignModel, viewed: GameEvent.Viewed) {
        switch settle {
        case .presentation(let payload, let entry):
            if entry == .inlineTeaser || entry == .floating {
                sdk.events.toDigia(viewed, payload: payload)
            } else {
                sdk.events.toBoth(.impressed, viewed, payload: payload)
            }
        case .rewards(let chanceId):
            sdk.events.toDigia(
                viewed,
                payload: Self.rewardsPayload(chanceId: chanceId, campaign: campaign))
        }
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

    /// `element_id` of the Clicked for a window's first `/play`, and for every later one.
    static let clickPlay = "play"
    static let clickPlayAgain = "play_again"

    /// `game_open_failed` reason for a skin download that outlived its
    /// presentation: the acceptance watchdog settled it before the open.
    static let downloadTimeoutReason = "download_timeout"

    /// The one `GameOpenRequest` builder: shared by entries, direct opens and
    /// rewards chances. Only the settle closures differ. The funnel counts a
    /// shown game: `shown` arms the failure Dismissed, so a game that never
    /// displayed reports only its open failure, never a Dismissed without a
    /// Viewed — like Android's `openRequest`. Internal for tests.
    func makeGameOpenRequest(
        file: URL,
        chanceId: String,
        config: GamificationConfig,
        campaign: CampaignModel,
        payload: CEPTriggerPayload,
        userId: String,
        settle: GameSettle,
        timing: GameOpenTiming = GameOpenTiming(intentAt: MonotonicClock.nowSeconds())
    ) -> GameOpenRequest {
        let campaignKey = campaign.campaignKey
        // The funnel counts a shown game: `shown` arms the failure Dismissed,
        // so a game that never displayed reports only its open failure, never
        // a Dismissed without a Viewed.
        var shown = false
        // What this window did, for `Dismissed`: one per open, so play again
        // and play next keep counting into the same window.
        let stats = GameFunnelStats(chanceId: chanceId)
        // The live-test invocation the trigger carried, if any: the grant was asked
        // with it, and both the skin's `state` call and the close-time `state` call
        // need it back so a draft campaign answers. Derived here — never stored —
        // so it cannot mismatch the grant.
        let openTestInvocationId: String?
        let entryValue: String
        switch settle {
        case .presentation(let presentationPayload, let entry):
            openTestInvocationId = testInvocationIdOf(presentationPayload.cepCampaignId)
            entryValue = entry.rawValue
        case .rewards:
            openTestInvocationId = nil
            entryValue = "rewards"
        }
        let dismissed: (String) -> GameEvent.Dismissed = { reason in
            GameEvent.Dismissed(
                reason: reason, dwellMs: stats.dwellMs(), chanceId: stats.chanceId,
                skinId: config.skinId, skinVersion: config.skinVersion,
                plays: stats.plays, playRefused: stats.playRefused, entry: entryValue)
        }
        let openedFromEntry: Bool
        if case .presentation(_, let entry) = settle, entry == .inlineTeaser || entry == .floating {
            openedFromEntry = true
        } else {
            openedFromEntry = false
        }
        let openedDirect: Bool
        if case .presentation(_, .direct) = settle {
            openedDirect = true
        } else {
            openedDirect = false
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
            showClose: config.showClose,
            onClose: { [weak self] reason in
                guard let self else { return }
                guard shown else {
                    self.closedBeforeShown(
                        settle: settle, campaign: campaign, config: config,
                        reason: reason, chanceId: stats.chanceId, timing: timing)
                    return
                }
                self.closed(
                    settle: settle, campaign: campaign, reason: reason, chanceId: stats.chanceId,
                    dismissed: dismissed(Self.gameDismissReason(closeReason: reason)))
            },
            onFailure: { [weak self] failure in
                guard let self else { return }
                // A shown game that dies Dismisses with `failure`; a game that
                // never displayed was never Viewed, so it reports only its
                // open failure.
                guard shown else {
                    self.fail(
                        settle: settle, campaign: campaign, config: config,
                        reason: failure.wireValue, chanceId: chanceId, timing: timing)
                    return
                }
                self.sdk.events.toDigia(
                    dismissed("failure"), payload: Self.payload(settle: settle, campaign: campaign))
                // A direct game that displayed and then died ends its
                // presentation; an entry's teaser stays and is kept or hidden
                // as after a close.
                if case .presentation(let payload, let entry) = settle {
                    switch entry {
                    case .direct, .unknown:
                        self.settleDirectFailure(payload: payload, reason: failure.wireValue)
                    case .inlineTeaser:
                        if openTestInvocationId == nil {
                            self.sdk.gamification.refreshRewardsIfLoaded()
                        }
                        self.refreshInlineEntryAfterClose(
                            campaignKey: campaignKey, payload: payload, chanceId: stats.chanceId)
                    case .floating:
                        if openTestInvocationId == nil {
                            self.sdk.gamification.refreshRewardsIfLoaded()
                        }
                        self.refreshFloatingEntryAfterClose(
                            campaignKey: campaignKey, payload: payload, chanceId: stats.chanceId)
                    }
                }
            },
            // A result action is a Digia click on its op, never a CEP one: the
            // CEP counts the tap that opened the game or its plays.
            onCta: { [weak self] op, actionUrl in
                guard let self else { return }
                self.sdk.events.toDigia(
                    GameEvent.Clicked(
                        elementId: op, chanceId: stats.chanceId, actionUrl: actionUrl, entry: entryValue),
                    payload: Self.payload(settle: settle, campaign: campaign))
            },
            onShown: { [weak self] in
                // A re-sent `ready` counts the impression once.
                guard !shown else { return }
                shown = true
                stats.start()
                // The skin's `state` answer arrived before `ready`, so this is the chance
                // the game plays, matching Clicked, Game Played and Dismissed.
                let viewed = GameEvent.Viewed(
                    chanceId: stats.chanceId, skinId: config.skinId, skinVersion: config.skinVersion,
                    warm: timing.warm ?? GamePrewarmer.warmKind(campaignKey: campaignKey),
                    tier: GamePrewarmer.deviceTier(), msToReady: timing.msElapsed, entry: entryValue)
                self?.shown(settle: settle, campaign: campaign, viewed: viewed)
            },
            onHttpAnswer: { [weak self] path, request, response in
                stats.recordHttp(path: path, request: request, response: response)
                guard let self, path == "play" else { return }
                let payload = Self.payload(settle: settle, campaign: campaign)
                // Every `/play` is a Digia click: `play` first, `play_again` after.
                // A Direct game also tells its CEP: the window holds the CEP slot until
                // it closes, so the click can still land. An entry-opened game's slot is
                // already released, so its plays stay Digia-only.
                let playNumber = stats.nextPlayNumber()
                // A game opened from an inline or floating entry already reported
                // the entry tap as its click, so its first play is not a click again;
                // a play again is a fresh tap on the game's own button.
                if !openedFromEntry || playNumber > 1 {
                    let elementId = playNumber == 1 ? Self.clickPlay : Self.clickPlayAgain
                    self.sdk.events.toDigia(
                        GameEvent.Clicked(elementId: elementId, chanceId: stats.chanceId, entry: entryValue),
                        payload: payload)
                    if openedDirect {
                        self.sdk.events.clicked(payload: payload, elementId: elementId)
                    }
                }
                // Game Played (and an extra play's Chance Granted) from the answer's
                // facts, to Digia only, never for a test invocation.
                if openTestInvocationId == nil {
                    self.sdk.events.forwardChanceEvents(
                        playEventsOf(
                            request: request, envelope: response, playNumber: playNumber, entry: entryValue),
                        payload: payload)
                }
            },
            // A watched skin `http` call hung with no answer: the game it stuck
            // closes through the normal path right after this (the presentation
            // closes on this callback). Always `game_rewards_failed` with the
            // hung path; plus `game_open_failed(http_timeout)` when the game
            // was already showing — the stuck window counts as an open
            // failure, unlike any other shown failure. Before shown, the
            // presentation fails instead and that path reports it once. The pair
            // is one frozen window in two streams (health and funnel): count a
            // shown hang once, do not sum `game_open_failed` with
            // `Dismissed(http_timeout)`.
            onHttpTimeout: { [weak self] path, durationMs in
                guard let self else { return }
                let health = GameHealthContext(
                    campaignId: campaign.id, skinId: config.skinId,
                    skinVersion: config.skinVersion, entry: entryValue)
                self.sdk.events.toDigia(
                    GameRewardsFailedEvent(
                        health: health, op: path,
                        code: GameBridgeError.timeout.rawValue, status: nil,
                        durationMs: durationMs),
                    payload: Self.payload(settle: settle, campaign: campaign))
                guard shown else { return }
                self.sdk.events.toDigia(
                    GameOpenFailedEvent(
                        reason: GameFailureReason.httpTimeout.wireValue,
                        chanceId: stats.chanceId, entry: entryValue,
                        skinId: config.skinId, skinVersion: config.skinVersion,
                        warm: timing.warm ?? GamePrewarmer.warmKind(campaignKey: campaignKey),
                        tier: GamePrewarmer.deviceTier(),
                        msElapsed: timing.msElapsed, stage: GameOpenTiming.stageReady),
                    payload: Self.payload(settle: settle, campaign: campaign))
            },
            onForeground: { stats.setForeground($0) },
            payload: payload,
            entry: entryValue,
            themeFontFamily: config.themeFontFamily,
            themeFonts: config.themeFonts,
            values: config.values,
            slots: config.slots,
            timing: timing
        )
    }

    /// Asks the backend `state` after a game opened from a floating entry
    /// closes, then keeps or hides the floater on the main thread. The floater
    /// stays on screen through the round-trip — hiding it there flickers it
    /// when the chance stays. With no user the call is skipped and the floater
    /// hides. A `played` answer keeps the floater only when
    /// `dismissAfterPlayed` is false; otherwise the floater comes down.
    private func refreshFloatingEntryAfterClose(
        campaignKey: String, payload: CEPTriggerPayload, chanceId: String
    ) {
        refreshEntryAfterClose(
            campaignKey: campaignKey, payload: payload, chanceId: chanceId,
            hide: { [weak self] in self?.hideFloatingEntry(payload) },
            onKept: { [weak self] in self?.rewarmEntry(payload) })
    }

    /// The open took the warm game and the engine, and the entry's impression
    /// does not fire again while it stays on screen, so warm both again now.
    private func rewarmEntry(_ payload: CEPTriggerPayload) {
        GamePrewarmer.refreshEngine()
        sdk.gamificationSurface.prewarmEntry(payload)
    }

    /// Hides a floating entry after its game closed: removes the stored
    /// chance and dismisses the
    /// floater — if it still shows this payload — as completed, never as a
    /// user close.
    private func hideFloatingEntry(_ payload: CEPTriggerPayload) {
        sdk.gamificationSurface.hideFloatingEntry(payload)
        if sdk.floaterStoryOrchestrator.state?.payload.cepCampaignId == payload.cepCampaignId {
            sdk.floaterStoryOrchestrator.dismiss(.completed)
        }
    }

    /// After a game opened from an inline entry closes: the card stays only
    /// when the close decision keeps it (`playable` with a fresh chance, a
    /// failed `state` call, or `played` with `dismissAfterPlayed: false` — a
    /// spent chance stays stored too, so a tap reopens the skin, whose own
    /// `state` call answers `played` and shows the reward already won).
    /// Otherwise the card is hidden: its chance is forgotten and its slot
    /// cleared as `.completed`, mirroring Android's `dismissInline`.
    private func refreshInlineEntryAfterClose(
        campaignKey: String, payload: CEPTriggerPayload, chanceId: String
    ) {
        refreshEntryAfterClose(
            campaignKey: campaignKey, payload: payload, chanceId: chanceId,
            hide: { [weak self] in self?.hideInlineEntry(payload) },
            onKept: { [weak self] in self?.rewarmEntry(payload) })
    }

    /// Hides an inline entry after its game closed: forgets the spent chance
    /// and clears its slot. The slot clear reports the CEP Dismissed through
    /// the inline removal path, like `hideFloatingEntry` does for floaters.
    private func hideInlineEntry(_ payload: CEPTriggerPayload) {
        sdk.gamificationSurface.hideInlineEntry(payload)
    }

    /// The one entry-close round-trip both entries share: with no user the
    /// entry hides at once, otherwise the backend `state` about `chanceId`, the
    /// chance the closed game was playing, decides. Not the stored chance: a
    /// re-trigger can replace it while the game is open, and play next moves
    /// the game to a newer chance. `played` and a failed call keep the stored chance (a
    /// reopen shows the outcome) — unless `dismissAfterPlayed` (top-level
    /// `templateConfig`, falling back to `surface`) says the entry dismisses
    /// after play, which is the default; any other non-playable answer runs `hide`.
    private func refreshEntryAfterClose(
        campaignKey: String,
        payload: CEPTriggerPayload,
        chanceId: String,
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
            let start = Date()
            let result = await self.sdk.gamification.gameOutcomeSource.state(
                campaignKey: campaignKey,
                testInvocationId: testInvocationIdOf(payload.cepCampaignId),
                chanceId: chanceId)
            if case .failed(let error) = result {
                // The close-time `state` failure reports like the rewards
                // fetch — and a timeout stays a timeout, never `network`.
                let campaign = self.sdk.campaignStore.find(campaignKey)
                let config = campaign?.gamificationConfig
                self.sdk.events.toDigia(
                    GameRewardsFailedEvent(
                        health: GameHealthContext(
                            campaignId: campaign?.id ?? "",
                            skinId: config?.skinId ?? "",
                            skinVersion: config?.skinVersion ?? 0,
                            entry: config?.entryKind.rawValue ?? ""),
                        op: "state",
                        code: error.rewardsCode,
                        status: error.rewardsStatus,
                        durationMs: Int(Date().timeIntervalSince(start) * 1000)),
                    payload: payload)
            }
            log.d("Gamification state after close (state=\(result))", campaign: campaignKey)
            // The entry's own campaign resolves a live test to its test
            // version; the store alone would read the published campaign.
            let dismissAfterPlayed = self.sdk.gamificationSurface.entryCampaign(payload)?
                .gamificationConfig?.dismissAfterPlayed
                ?? self.sdk.campaignStore.find(campaignKey)?.gamificationConfig?.dismissAfterPlayed
                ?? true
            switch PlaySession.decideAfterClose(result, dismissAfterPlayed: dismissAfterPlayed) {
            case .keep(let replacement):
                if let replacement {
                    self.sdk.gamificationSurface.chances[
                        GamificationSurface.entryKey(payload)] = replacement
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
}
