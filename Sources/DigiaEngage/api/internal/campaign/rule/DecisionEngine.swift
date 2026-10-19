import Foundation

/// The SDK's one logging style — see ``DigiaLogger``.
private let log = DigiaLogger()

/// What the ``DecisionEngine`` reads from the SDK when it decides.
@MainActor
protocol DecisionFacts: AnyObject {
    /// The SDK is ready and its campaigns are loaded.
    var ready: Bool { get }
    func listeningTo(_ signal: RuleSignal) -> [CampaignModel]
    func find(_ campaignKey: String) -> CampaignModel?
    var attributes: [String: Any] { get }
    var device: [String: Any] { get }
    func inAudience(_ campaign: CampaignModel) -> Bool
    func capped(_ campaign: CampaignModel) -> Bool
    /// The screen now, or empty.
    var currentScreen: String { get }
    /// The key of the campaign in `slot`, if any.
    func slotCampaignKey(_ slot: String) -> String?
    /// The audience state, for the `not_in_audience` log.
    var audienceContext: String { get }
}

/// Shows a campaign the SDK fired itself; `firedBy` names the cause in logs.
typealias RouteCampaign = (CampaignModel, String, RuleSignal) -> Void

/// Decides which Digia-owned campaign a signal shows: holds signals until
/// `ready`, evaluates them one at a time, runs waits, and hands each winner to
/// the injected router.
@MainActor
final class DecisionEngine {
    private let facts: DecisionFacts
    private let route: RouteCampaign
    private let nowMs: () -> Int
    lazy var waits = Waits(
        onElapsed: { [weak self] due in self?.onWaitsElapsed(due) }, nowMs: nowMs)
    private lazy var gate: SignalGate = {
        let bus = SignalBus { [weak self] signal, ageMs in
            self?.evaluate(signal, ageMs: ageMs)
        }
        return SignalGate(
            send: { signal, ageMs in bus.send(signal, ageMs: ageMs) }, nowMs: nowMs)
    }()

    /// Reports each unusable rule once per session, not on every signal.
    private var reportedRuleFailures: Set<String> = []
    private var reportedDefaultPriority: Set<String> = []

    init(facts: DecisionFacts, route: @escaping RouteCampaign, nowMs: @escaping () -> Int) {
        self.facts = facts
        self.route = route
        self.nowMs = nowMs
    }

    /// Held until ``ready()``, then evaluated.
    func send(_ signal: RuleSignal) {
        gate.send(signal)
    }

    var isReady: Bool { gate.isOpen }

    /// The campaigns and user context are loaded: replays the held signals.
    func ready() {
        gate.open()
    }

    /// Loading failed or the SDK was reset: drops what was held and holds again.
    func close() {
        gate.close()
    }

    /// The app went to the background before ready: drops what was held.
    func dropHeld() {
        gate.dropHeld()
    }

    /// The app left the screen: waits keep counting but do not fire.
    func pause() {
        waits.pause()
    }

    /// The app is back: fires every wait that ended meanwhile.
    func resume() {
        waits.resume()
    }

    /// Evaluates the Digia-owned rules that listen for `signal` and routes the
    /// eligible campaign with the highest priority.
    private func evaluate(_ signal: RuleSignal, ageMs: Int) {
        guard facts.ready, gate.isOpen else { return }
        // Cancels first, so the signal that starts a wait cannot also end it.
        cancelWaits(signal)
        let decision = pickCampaign(
            facts.listeningTo(signal),
            signal: signal,
            attributes: facts.attributes,
            device: facts.device,
            isWaiting: { self.waits.isWaiting($0) },
            inAudience: facts.inAudience,
            capped: facts.capped
        )
        for skip in decision.skipped {
            switch skip {
            case .alreadyWaiting(let campaign):
                logAlreadyWaiting(campaign.campaignKey)
            case .ineligible(let campaign, let reason, let detail):
                reportIneligible(campaign, reason: reason, detail: detail)
            }
        }
        routeInlineWinners(decision.inlineWinners, signal: signal)
        routeWinner(decision, signal: signal)
        // After the winner: a wait that already ended, as for a held signal,
        // fires at once and must not take the surface ahead of it.
        startRuleWaits(decision.waiting, signal: signal, ageMs: ageMs)
    }

    private func routeWinner(_ decision: RuleDecision, signal: RuleSignal) {
        guard let winner = decision.winner, let winnerRule = decision.winnerRule else { return }
        for campaign in [winner] + decision.heldBack {
            reportDefaultedPriority(campaign)
        }
        for loser in decision.heldBack {
            let loserPriority = loser.rule?.priority
            let why =
                loserPriority == winnerRule.priority
                ? "wins the tie by campaign key"
                : "has a higher priority"
            let priorityText = formatPriority(loserPriority)
            log.d(
                "Not shown — \(winner.campaignKey) \(why) "
                    + "(priority \(formatPriority(winnerRule.priority)) vs \(priorityText))",
                campaign: loser.campaignKey,
                stage: .gating,
                reason: TimelineReason.lowerPriority,
                extras: [
                    "verdict": "eligible",
                    "outcome": "held_back",
                    "lost_to": winner.campaignKey,
                ]
            )
        }
        route(winner, signal.name, signal)
    }

    /// Routes each slot's winner as its own presentation, at once: an inline
    /// campaign's wait is ignored. A winner already in its slot is skipped, so a
    /// frequent trigger neither drops it `surface_busy` nor replaces it.
    private func routeInlineWinners(_ winners: [SlotWinner], signal: RuleSignal) {
        for slotWinner in winners {
            let campaign = slotWinner.campaign
            if facts.slotCampaignKey(slotWinner.slot) == campaign.campaignKey {
                log.d(
                    "Skipped — already in slot \(slotWinner.slot)",
                    campaign: campaign.campaignKey)
                continue
            }
            for candidate in [campaign] + slotWinner.heldBack {
                reportDefaultedPriority(candidate)
            }
            for loser in slotWinner.heldBack {
                log.d(
                    "Not shown — \(campaign.campaignKey) wins slot \(slotWinner.slot)",
                    campaign: loser.campaignKey,
                    stage: .gating,
                    reason: TimelineReason.lowerPriority,
                    extras: [
                        "verdict": "eligible",
                        "outcome": "held_back",
                        "lost_to": campaign.campaignKey,
                    ]
                )
            }
            if case .valid(let rule)? = campaign.rule, rule.wait != nil {
                log.d(
                    "Wait ignored — an inline campaign shows at once",
                    campaign: campaign.campaignKey)
            }
            route(campaign, signal.name, signal)
        }
    }

    private func startRuleWaits(
        _ waiting: [(CampaignModel, ValidRule)],
        signal: RuleSignal,
        ageMs: Int
    ) {
        guard !waiting.isEmpty else { return }
        for (campaign, rule) in waiting {
            guard let wait = rule.wait else { continue }
            log.d(
                "Waiting \(wait.ms) ms before the campaign shows",
                campaign: campaign.campaignKey,
                stage: .gating,
                reason: TimelineReason.waitStarted,
                extras: ["ms": String(wait.ms)]
            )
        }
        waits.start(
            waiting.compactMap { campaign, rule in
                guard let wait = rule.wait else { return nil }
                return (campaign.campaignKey, rule.priority, wait)
            },
            trigger: signal,
            screen: facts.currentScreen,
            elapsedMs: ageMs
        )
    }

    /// Ends the waits `signal` cancels, before it is queued, so a wait cannot
    /// end while the signal is in flight.
    func cancelWaits(_ signal: RuleSignal) {
        for (pending, cause) in waits.cancelMatching(signal) {
            logWaitCancelled(pending, cause: cause)
        }
    }

    private func logAlreadyWaiting(_ campaignKey: String) {
        log.d(
            "Ignored — the campaign already waits",
            campaign: campaignKey,
            stage: .gating,
            reason: TimelineReason.waitInProgress)
    }

    private func logWaitCancelled(_ pending: PendingWait, cause: WaitCancelCause) {
        log.d(
            "Wait cancelled — \(cause.wire)",
            campaign: pending.campaignKey,
            stage: .gating,
            reason: TimelineReason.waitCancelled,
            extras: ["cause": cause.wire]
        )
    }

    /// The session ended: drops held signals and ends every wait.
    func reset() {
        reportedRuleFailures.removeAll()
        reportedDefaultPriority.removeAll()
        gate.dropHeld()
        for pending in waits.cancelAll() {
            logWaitCancelled(pending, cause: .sessionEnded)
        }
    }

    /// Waits that ended at the same moment, highest priority first: the first
    /// that is still eligible routes, the rest find the surface busy (D4).
    private func onWaitsElapsed(_ due: [PendingWait]) {
        var winner: String?
        for pending in due {
            if let winner {
                log.d(
                    "Dropped — surface busy, \(winner) shows",
                    campaign: pending.campaignKey,
                    stage: .gating,
                    reason: DropReason.surfaceBusy,
                    extras: ["blocking": winner]
                )
            } else if onWaitElapsed(pending) {
                winner = pending.campaignKey
            }
        }
    }

    /// A wait ran its full time: check the campaign again with the trigger's
    /// properties and current user values, then route it. Returns whether it
    /// routed. Never throws.
    private func onWaitElapsed(_ pending: PendingWait) -> Bool {
        let key = pending.campaignKey
        let campaign = facts.ready ? facts.find(key) : nil
        guard let campaign else {
            logWaitEnded(key, outcome: "gone", waitMs: pending.wait.ms)
            return false
        }
        let verdict = evaluateOne(
            campaign, trigger: pending.trigger,
            attributes: facts.attributes, device: facts.device)
        guard let verdict else {
            logWaitEnded(key, outcome: "gone", waitMs: pending.wait.ms)
            return false
        }
        if verdict.kind == .notTriggered {
            logWaitEnded(key, outcome: "rule_changed", waitMs: pending.wait.ms)
            return false
        }
        logWaitEnded(key, outcome: "checked", waitMs: pending.wait.ms)
        if let reason = ineligibility(
            campaign, verdict: verdict, inAudience: facts.inAudience, capped: facts.capped)
        {
            reportIneligible(campaign, reason: reason, detail: verdict.detail)
            return false
        }
        // On a timer, routing must cost at most this campaign, never the app.
        route(campaign, "\(pending.trigger.name) after wait", pending.trigger)
        return true
    }

    private func logWaitEnded(_ campaignKey: String, outcome: String, waitMs: Int) {
        let message =
            outcome == "gone"
            ? "Wait ended — the campaign is no longer live"
            : outcome == "rule_changed"
                ? "Wait ended — the rule changed and no longer matches"
                : "Wait ended after \(waitMs) ms"
        log.d(
            message,
            campaign: campaignKey,
            stage: .gating,
            reason: TimelineReason.waitEnded,
            extras: ["outcome": outcome]
        )
    }

    /// Bad server data; logged once per campaign per session.
    private func reportDefaultedPriority(_ campaign: CampaignModel) {
        guard case .valid(let rule)? = campaign.rule, rule.priorityDefaulted else { return }
        guard reportedDefaultPriority.insert(campaign.campaignKey).inserted else { return }
        log.w(
            "Missing or invalid priority — counted as \(formatPriority(defaultPriority))",
            campaign: campaign.campaignKey,
            stage: .gating
        )
    }

    private func reportIneligible(
        _ campaign: CampaignModel,
        reason: TimelineReason,
        detail: String?
    ) {
        var broken: [String: String]?
        switch reason {
        case .unsupportedFeature:
            broken = ["feature": detail ?? ""]
        case .malformedRule:
            let isParse: Bool
            if case .invalid? = campaign.rule { isParse = true } else { isParse = false }
            broken = ["exception_class": isParse ? "parse" : (detail ?? "")]
        default:
            broken = nil
        }
        if let broken {
            // Bad server data; logged once per campaign per session.
            guard reportedRuleFailures.insert(campaign.campaignKey).inserted else { return }
            log.w(
                "Ineligible — \(reason.wire): \(detail ?? "")",
                campaign: campaign.campaignKey,
                stage: .gating,
                reason: reason,
                extras: ["verdict": "ineligible"].merging(broken) { $1 }
            )
            return
        }
        var extras = ["verdict": "ineligible"]
        if reason == .conditionFailed { extras["condition"] = detail ?? "" }
        if reason == .notInAudience { extras["context"] = facts.audienceContext }
        log.d(
            "Ineligible — \(reason.wire)",
            campaign: campaign.campaignKey,
            stage: .gating,
            reason: reason,
            extras: extras
        )
    }

    private func formatPriority(_ value: Double?) -> String {
        guard let value else { return "?" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}
