import Foundation

/// A triggered campaign that did not join the priority contest.
enum SkippedCampaign {
    /// The campaign already waits; the signal does not start it again.
    case alreadyWaiting(CampaignModel)
    case ineligible(CampaignModel, TimelineReason, String?)
}

/// The winner of one inline slot. It is routed besides the overlay winner.
struct SlotWinner {
    let slot: String
    let campaign: CampaignModel
    /// The other eligible campaigns for `slot`, in `compareByPriority` order.
    let heldBack: [CampaignModel]
}

/// The result of one evaluation. The caller logs, waits and routes.
struct RuleDecision {
    /// In campaign order.
    let skipped: [SkippedCampaign]
    let winner: CampaignModel?
    let winnerRule: ValidRule?
    /// Eligible overlays without a wait and a lower priority than `winner`, in
    /// `compareByPriority` order.
    let heldBack: [CampaignModel]
    /// Eligible campaigns with a wait. Each starts its own; they compete when
    /// they end.
    let waiting: [(CampaignModel, ValidRule)]
    /// One winner per inline slot, in the order the slots first appear. Inline
    /// campaigns never compete for `winner` and never wait.
    let inlineWinners: [SlotWinner]
}

/// Evaluates the Digia-owned rules in `campaigns` against `signal`: the
/// eligible overlay without a wait and with the highest priority shows now,
/// every eligible overlay with a wait starts it, and the eligible inline
/// campaign with the highest priority wins each slot; a tie goes to the
/// campaign key that sorts first. Has no side effects. Never throws.
func pickCampaign(
    _ campaigns: [CampaignModel],
    signal: RuleSignal,
    attributes: [String: Any],
    device: [String: Any],
    isWaiting: (String) -> Bool,
    inAudience: (CampaignModel) -> Bool,
    capped: (CampaignModel) -> Bool
) -> RuleDecision {
    var skipped: [SkippedCampaign] = []
    var eligible: [(CampaignModel, ValidRule)] = []
    for campaign in campaigns {
        // A campaign with no rule belongs to a CEP, which calls in itself.
        guard let rule = campaign.rule else { continue }
        let verdict = RuleEvaluator.evaluate(
            rule, signal, attributes: attributes, device: device)
        if verdict.kind == .notTriggered { continue }
        if isWaiting(campaign.campaignKey) {
            skipped.append(.alreadyWaiting(campaign))
            continue
        }
        if let reason = ineligibility(
            campaign, verdict: verdict, inAudience: inAudience, capped: capped)
        {
            skipped.append(.ineligible(campaign, reason, verdict.detail))
            continue
        }
        guard case .valid(let validRule) = rule else { continue }
        eligible.append((campaign, validRule))
    }
    eligible.sort {
        compareByPriority(
            $0.1.priority, $0.0.campaignKey,
            $1.1.priority, $1.0.campaignKey) < 0
    }
    var bySlot: [String: [CampaignModel]] = [:]
    var slotOrder: [String] = []
    var now: [(CampaignModel, ValidRule)] = []
    var waiting: [(CampaignModel, ValidRule)] = []
    for entry in eligible {
        if let slot = entry.0.inlineSlotKey {
            if bySlot[slot] == nil { slotOrder.append(slot) }
            bySlot[slot, default: []].append(entry.0)
        } else if entry.1.wait == nil {
            now.append(entry)
        } else {
            waiting.append(entry)
        }
    }
    return RuleDecision(
        skipped: skipped,
        winner: now.first?.0,
        winnerRule: now.first?.1,
        heldBack: now.dropFirst().map { $0.0 },
        waiting: waiting,
        inlineWinners: slotOrder.map { slot in
            let campaigns = bySlot[slot] ?? []
            return SlotWinner(
                slot: slot, campaign: campaigns[0],
                heldBack: Array(campaigns.dropFirst()))
        }
    )
}

/// Higher priority first; equal priorities by campaign key, ascending in
/// UTF-16 code-unit order, so every SDK picks the same winner
/// (dmc-rule-test-vectors).
func compareByPriority(
    _ aPriority: Double, _ aKey: String,
    _ bPriority: Double, _ bKey: String
) -> Int {
    if aPriority != bPriority { return aPriority > bPriority ? -1 : 1 }
    if aKey == bKey { return 0 }
    return aKey < bKey ? -1 : 1
}

/// Why an evaluated campaign may not show, or nil when it may.
func ineligibility(
    _ campaign: CampaignModel,
    verdict: RuleVerdict,
    inAudience: (CampaignModel) -> Bool,
    capped: (CampaignModel) -> Bool
) -> TimelineReason? {
    switch verdict.reason {
    case .unsupportedFeature: return .unsupportedFeature
    case .malformedRule: return .malformedRule
    case .conditionFailed: return .conditionFailed
    case nil where !inAudience(campaign): return .notInAudience
    case nil where capped(campaign): return .capped
    default: return nil
    }
}

/// Evaluates one campaign against `trigger`. Nil when it has no rule, so the
/// caller reports it gone. Pure; never throws.
func evaluateOne(
    _ campaign: CampaignModel,
    trigger: RuleSignal,
    attributes: [String: Any],
    device: [String: Any]
) -> RuleVerdict? {
    guard let rule = campaign.rule else { return nil }
    return RuleEvaluator.evaluate(rule, trigger, attributes: attributes, device: device)
}
