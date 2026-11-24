import Foundation

/// The chance events a `grantChance` answer's facts call for. The server no longer
/// sends events; it says what happened and the SDK reports it:
/// - `Gamification Assigned` iff the answer carries `holdout`;
/// - `Chance Granted` (source `trigger`) iff granted and `isNew`;
/// - `Chance Denied` iff denied with a `denyReason`, `isNew` and a `campaignId`.
///
/// None for a test invocation. Never throws: a missing or mistyped fact is no
/// event. Mirrors Android's `grantEventsOf`.
func grantEventsOf(
    _ answer: [String: Any],
    granted: Bool,
    chanceId: String?,
    testInvocationId: String?
) -> [ChanceEvent] {
    if testInvocationId != nil { return [] }
    let isNew = isTrue(answer["isNew"])
    var out: [ChanceEvent] = []
    if let holdout = answer["holdout"] as? [String: Any],
       let group = text(holdout, "group"),
       let period = ChanceNumber(holdout["period"])
    {
        out.append(.assigned(GamificationAssigned(group: group, period: period)))
    }
    if granted, isNew, let chanceId {
        out.append(.granted(ChanceGranted(
            chanceId: chanceId, source: ChanceGranted.sourceTrigger,
            expiresAt: text(answer, "expiresAt"))))
    }
    if !granted, isNew, let denyReason = text(answer, "denyReason"),
       text(answer, "campaignId") != nil
    {
        out.append(.denied(ChanceDenied(reason: denyReason, cap: text(answer, "cap"))))
    }
    return out
}

/// The chance events a proxied `play` answer's facts call for: `Game Played` iff
/// the answer is `isNew` (the play it made, never a replay of an earlier answer),
/// plus `Chance Granted` (source `extraPlay`) when it carries an `extraChance`.
/// `request` is the skin's `/play` body (its `chanceId`); `envelope` is
/// `{isSuccess, data: {response}}`. `playNumber` is this play's 1-based number in
/// the window; `entry` is where the window opened, carried on `Game Played`. The
/// caller gates test invocations. Mirrors Android's `playEventsOf`.
func playEventsOf(
    request: [String: Any]?, envelope: Any?, playNumber: Int, entry: String? = nil
) -> [ChanceEvent] {
    guard let data = (envelope as? [String: Any])?["data"] as? [String: Any],
          let answer = data["response"] as? [String: Any],
          isTrue(answer["isNew"])
    else { return [] }
    let grant = answer["grant"] as? [String: Any]
    let value = grant?["value"] as? [String: Any]
    var out: [ChanceEvent] = [
        .played(GamePlayed(
            chanceId: request.flatMap { text($0, "chanceId") },
            outcomeKey: text(answer, "outcomeKey"),
            outcomeKind: text(answer, "kind"),
            rewardId: text(answer, "rewardId"),
            grantId: grant.flatMap { text($0, "grantId") },
            valueMinor: ChanceNumber(value?["amountMinor"]),
            currency: value.flatMap { text($0, "currency") },
            fallback: isTrue(answer["fallback"]),
            playNumber: playNumber,
            entry: entry)),
    ]
    if let extra = answer["extraChance"] as? [String: Any],
       let chanceId = text(extra, "chanceId")
    {
        out.append(.granted(ChanceGranted(
            chanceId: chanceId, source: ChanceGranted.sourceExtraPlay,
            expiresAt: text(extra, "expiresAt"))))
    }
    return out
}

extension PlayDecision {
    /// The chance events a grant answer led to, whatever the decision.
    var chanceEvents: [ChanceEvent] {
        switch self {
        case .open(let chance), .showEntry(let chance): return chance.events
        case .drop(_, _, let events): return events
        }
    }
}

extension EngageEventEmitter {
    /// Sends chance events to Digia analytics only — never the CEP.
    func forwardChanceEvents(_ events: [ChanceEvent], payload: CEPTriggerPayload) {
        for event in events { toDigia(event, payload: payload) }
    }
}

/// A JSON `true` only: JSONSerialization hands booleans as `NSNumber`, and a
/// number 1 is not a boolean.
private func isTrue(_ raw: Any?) -> Bool {
    guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
    return n.boolValue
}

/// A string that is not blank, else nil.
private func text(_ json: [String: Any], _ key: String) -> String? {
    guard let value = json[key] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    return value
}
