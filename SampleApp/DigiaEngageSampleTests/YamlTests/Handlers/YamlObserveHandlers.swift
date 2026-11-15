import Foundation
@testable import DigiaEngage

/// What the SDK sent and decided: analytics events, calls on the CEP plugin
/// and structured diagnostic records. Mirrors `handlers/observe.dart`.
let yamlObserveHandlers: [String: YamlHandler] = [
    "assertEvents": { try await check($0, "events", events($0), $1) },
    "assertCep": { try await check($0, "CEP calls", cepCalls($0), $1) },
    "assertLog": { try await check($0, "log records", logRecords($0), $1) },
    "assertDecision": unsupported(
        "iOS emits no DMC decision records: campaigns carry no rule engine, so there is " +
        "no rule_fired, no wait and no verdict to assert. Needs the diagnostics spine " +
        "(proposal §8) before this command can mean anything here."),
]

/// Every `/track` request body event as the server received it (wire keys
/// such as `event_name`, `campaign_key`, `properties`), after a flush.
/// `sdk_health` diagnostics share the wire but are not events a test asserts.
@MainActor private func events(_ world: YamlWorld) async -> [[String: Any]] {
    let sdk = SDKInstance.shared
    sdk.services?.analyticsService?.flush()
    await world.settle()
    return world.network.logSnapshot(from: world.eventBaseline)
        .filter { $0.endpoint == "track" }
        .flatMap { entry -> [[String: Any]] in
            guard let body = entry.body as? [String: Any],
                  let list = body["events"] as? [[String: Any]]
            else { return [] }
            return list
        }
        .filter { ($0["event_name"] as? String) != "sdk_health" }
}

/// `{ call: trigger, campaignKey, cepCampaignId, accepted, state, outcome,
/// reason }` for every delivery (`outcome`/`reason` once it settled), plus
/// `{ call: setup|teardown|onScreenChanged|trackEvent, ... }` in call order.
@MainActor private func cepCalls(_ world: YamlWorld) -> [[String: Any]] {
    world.cep.calls + world.cep.deliveries.map { trigger($0.trigger, $0.presentation) }
}

@MainActor private func trigger(
    _ payload: CEPTriggerPayload, _ presentation: any CampaignPresentation
) -> [String: Any] {
    let outcome = presentation.outcome.settledValue
    let accepted: Bool = {
        if case .dropped = outcome { return false }
        return true
    }()
    var out: [String: Any] = [
        "call": "trigger",
        "campaignKey": payload.campaignKey,
        "cepCampaignId": payload.cepCampaignId,
        "accepted": accepted,
        "state": presentation.state.value,
    ]
    switch outcome {
    case .dismissed(let reason, _):
        out["outcome"] = "dismissed"
        out["reason"] = reason.value
    case .dropped(let reason, _):
        out["outcome"] = "dropped"
        out["reason"] = reason.value
    case nil:
        break
    }
    return out
}

/// `{ stage, reason, campaignKey, presentationId, screenName, severity,
/// extras: {...} }` for each record that carries a stage (the ones a
/// campaign creator may see). Never the free-text message.
@MainActor private func logRecords(_ world: YamlWorld) -> [[String: Any]] {
    world.logSink.records.map { record in
        var out: [String: Any] = [:]
        if let stage = record.stage { out["stage"] = stage.wire }
        if let reason = record.reason { out["reason"] = reason.wire }
        if let key = record.campaignKey { out["campaignKey"] = key }
        if let id = record.presentationId { out["presentationId"] = id }
        if let screen = record.screenName { out["screenName"] = screen }
        out["severity"] = "\(record.severity)"
        out["extras"] = record.extras
        return out
    }
}

/// `contains`, `notContains`, `inOrder` (a subsequence) and `exactly`, over
/// [actual]. Fails listing every actual item.
@MainActor private func check(
    _ world: YamlWorld, _ what: String, _ actual: [[String: Any]], _ args: [String: Any]
) async throws {
    func list(_ key: String) -> [Any] { args[key] as? [Any] ?? [] }
    var problems: [String] = []

    for want in list("contains") {
        if !actual.contains(where: { YamlMatch.matches($0, want) }) {
            problems.append("contains: nothing matches \(YamlMatch.json(want))")
        }
    }
    for want in list("notContains") {
        if let hit = actual.first(where: { YamlMatch.matches($0, want) }) {
            problems.append("notContains: \(YamlMatch.json(want)) matched \(YamlMatch.json(hit))")
        }
    }
    if args.keys.contains("inOrder") {
        let wants = list("inOrder")
        var from = 0
        for want in wants {
            if let at = actual[from...].firstIndex(where: { YamlMatch.matches($0, want) }) {
                from = at + 1
            } else {
                problems.append("inOrder: \(YamlMatch.json(want)) not found" +
                    (from == 0 ? "" : " after item \(from)") + " in order")
                break
            }
        }
    }
    if args.keys.contains("exactly") {
        let wants = list("exactly")
        if wants.count != actual.count {
            problems.append("exactly: expected \(wants.count) items, got \(actual.count)")
        } else {
            for (index, want) in wants.enumerated() {
                if !YamlMatch.matches(actual[index], want) {
                    problems.append("exactly: item \(index + 1) is not \(YamlMatch.json(want))")
                    break
                }
            }
        }
    }

    if problems.isEmpty { return }
    throw YamlTestFailure(
        problems.joined(separator: "\n           "),
        expected: "the \(what) to satisfy the check",
        actual: "\(actual.count) \(what):\n\(numbered(actual))",
        line: world.step.line)
}

@MainActor private func numbered(_ items: [[String: Any]]) -> String {
    items.enumerated()
        .map { "    \($0.offset + 1). \(YamlMatch.json($0.element))" }
        .joined(separator: "\n")
}
