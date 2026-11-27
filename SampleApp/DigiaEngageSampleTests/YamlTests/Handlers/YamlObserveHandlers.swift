import Foundation
@testable import DigiaEngage

/// What the SDK sent and decided: analytics events, calls on the CEP plugin
/// and structured diagnostic records. Mirrors `handlers/observe.dart`.
let yamlObserveHandlers: [String: YamlHandler] = [
    "assertEvents": { try await check($0, "events", events($0), $1) },
    "assertCep": { try await check($0, "CEP calls", cepCalls($0), $1) },
    "assertLog": assertLog,
    "assertAppEvents": { try await check($0, "app events", appEvents($0), $1) },
    "assertHealth": { try await check($0, "health rows", healthRows($0), $1) },
    "assertDecision": assertDecision,
    "assertOpenedLinks": assertOpenedLinks,
]

/// The links the SDK opened since the first launchApp, in order: what went
/// through the action platform the driver records (CTA links, survey
/// redirects). Mirrors `assertOpenedLinks` in the Flutter driver.
@MainActor private func assertOpenedLinks(_ world: YamlWorld, _ args: [String: Any]) async throws {
    if args.isEmpty {
        throw YamlTestFailure("assertOpenedLinks checks nothing",
                              expected: "contains, notContains or exactly", line: world.step.line)
    }
    await world.settle()
    let opened = world.platform.opened
    var problems: [String] = []
    for want in args["contains"] as? [Any] ?? [] where !opened.contains("\(want)") {
        problems.append("contains: \(want) not opened")
    }
    for want in args["notContains"] as? [Any] ?? [] where opened.contains("\(want)") {
        problems.append("notContains: \(want) opened")
    }
    if let want = args["exactly"] as? [Any], want.map({ "\($0)" }) != opened {
        problems.append("exactly: expected \(want.map { "\($0)" })")
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(problems.joined(separator: "\n           "),
                          expected: "the opened links to match",
                          actual: "\(opened.count) opened: \(opened)", line: world.step.line)
}

/// Every `/track` request body since the clearState launch, after both
/// queues flushed. Health rows and app events boot itself sends count too.
@MainActor private func trackBodies(_ world: YamlWorld) async -> [[String: Any]] {
    for _ in 0..<2 {
        SDKInstance.shared.services?.flushAnalytics()
        await world.settle()
    }
    return world.network.logSnapshot(from: world.apiBaseline)
        .filter { $0.endpoint == "track" }
        .compactMap { $0.body as? [String: Any] }
}

/// The host app events the server received: each `/track` body's `appEvents`.
@MainActor private func appEvents(_ world: YamlWorld) async -> [[String: Any]] {
    await trackBodies(world).flatMap { $0["appEvents"] as? [[String: Any]] ?? [] }
        .filter(world.isFromThisInstall)
}

/// The `sdk_health` rows the server received, flattened to `{ reason, stage,
/// campaignKey, detail }`.
@MainActor private func healthRows(_ world: YamlWorld) async -> [[String: Any]] {
    await trackBodies(world)
        .flatMap { $0["events"] as? [[String: Any]] ?? [] }
        .filter { ($0["event_name"] as? String) == "sdk_health" && world.isFromThisInstall($0) }
        .map { event in
            let properties = event["properties"] as? [String: Any] ?? [:]
            var row: [String: Any] = [
                "reason": properties["reason"] ?? NSNull(),
                "stage": properties["stage"] ?? NSNull(),
                "detail": properties["detail"] ?? [String: Any](),
            ]
            if let key = event["campaign_key"], !(key is NSNull) { row["campaignKey"] = key }
            return row
        }
}

/// `contains` / `notContains` over the records, and `count: { match, equals }`.
@MainActor private func assertLog(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let records = logRecords(world)
    try await check(world, "log records", records, args)
    guard let count = args["count"] as? [String: Any] else { return }
    guard let want = count["equals"] as? Int, let match = count["match"] as? [String: Any] else {
        throw YamlTestFailure(
            "assertLog count needs match and equals",
            expected: "count: { match: {...}, equals: 1 }",
            line: world.step.line)
    }
    let got = records.filter { YamlMatch.matches($0, match) }.count
    if got != want {
        throw YamlTestFailure(
            "count: \(YamlMatch.json(match)) matched \(got) records",
            expected: "\(want)",
            actual: "\(got) of \(records.count) records:\n\(numbered(records))",
            line: world.step.line)
    }
}

/// The held-back reasons, by wire symbol, as the rule cases name them.
private let heldBackReasons: [String: String] = [
    "lower_priority": "lowerPriority",
    "capped": "capped",
    "not_in_audience": "notInAudience",
    "not_on_target_screen": "notOnTargetScreen",
]

/// The rule cases' `expect` block over the diagnostic records written since
/// the previous `assertDecision` (or since boot). Mirrors `_assertDecision`.
@MainActor private func assertDecision(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let all = world.logSink.records
    let window = Array(all[min(world.decisionMark, all.count)...])
    world.decisionMark = all.count
    var problems: [String] = []

    func keys(of reason: String) -> [String] {
        window.compactMap { $0.reason?.wire == reason ? $0.campaignKey : nil }.sorted()
    }
    func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).map { "\($0)" }.sorted()
    }

    if args.keys.contains("shown") {
        let want = args["shown"]
        let wanted: [String]
        if want == nil || want is NSNull {
            wanted = []
        } else if want is [Any] {
            wanted = strings(want)
        } else {
            wanted = ["\(want!)"]
        }
        let got = keys(of: "rule_fired")
        if got != wanted {
            problems.append("shown: expected \(wanted.isEmpty ? "nothing" : wanted.joined(separator: ", ")), "
                + "got \(got.isEmpty ? "nothing" : got.joined(separator: ", "))")
        }
    }
    if let want = args["heldBack"] as? [String: Any] {
        var got: [String: Any] = [:]
        for record in window {
            if let key = record.campaignKey, let wire = record.reason?.wire,
               let name = heldBackReasons[wire]
            {
                got[key] = name
            }
        }
        if !YamlMatch.matches(got, want) || got.count != want.count {
            problems.append("heldBack: expected \(want), got \(got)")
        }
    }
    for (key, reason) in [("waiting", "wait_started"), ("waitCancelled", "wait_cancelled")] {
        if args[key] is [Any] {
            let want = strings(args[key])
            let got = keys(of: reason)
            if want != got { problems.append("\(key): expected \(want), got \(got)") }
        }
    }
    if let want = args["waitCancelCauses"] as? [String: Any] {
        var got: [String: Any] = [:]
        for record in window where record.reason?.wire == "wait_cancelled" {
            if let key = record.campaignKey { got[key] = record.extras["cause"] ?? "" }
        }
        if !YamlMatch.matches(got, want) || got.count != want.count {
            problems.append("waitCancelCauses: expected \(want), got \(got)")
        }
    }
    if let verdicts = args["verdicts"] as? [String: Any] {
        for (key, raw) in verdicts.sorted(by: { $0.key < $1.key }) {
            let want = raw as? [String: Any] ?? [:]
            let got = verdict(window, key)
            let reasonOk = want.keys.contains("reason")
                ? (want["reason"] as? String) == got.reason
                : got.reason == nil
            if (want["verdict"] as? String) != got.verdict || !reasonOk {
                problems.append("verdict of \(key): expected \(want), got {verdict: \(got.verdict)"
                    + (got.reason.map { ", reason: \($0)" } ?? "") + "}")
            }
        }
    }

    if problems.isEmpty { return }
    throw YamlTestFailure(
        problems.joined(separator: "\n           "),
        expected: "the decision of this window to match",
        actual: "\(window.count) records since the last assertDecision:\n"
            + numbered(window.map(record)),
        line: world.step.line)
}

/// What the rule said about [key] in [window]: `ineligible` carries the
/// reason the record names; a fired or held-back campaign was `eligible`.
private func verdict(_ window: [TimelineRecord], _ key: String) -> (verdict: String, reason: String?) {
    for record in window where record.campaignKey == key {
        switch record.extras["verdict"] {
        case "ineligible": return ("ineligible", record.reason?.wire)
        case "eligible": return ("eligible", nil)
        default: break
        }
        if record.reason?.wire == "rule_fired" { return ("eligible", nil) }
    }
    return ("not_triggered", nil)
}

/// Every `/track` request body event as the server received it (wire keys
/// such as `event_name`, `campaign_key`, `properties`), after a flush.
/// `sdk_health` diagnostics share the wire but are not events a test asserts.
@MainActor private func events(_ world: YamlWorld) async -> [[String: Any]] {
    let sdk = SDKInstance.shared
    // Drain, don't snapshot once: flush, let the upload land, and repeat
    // until the fake sees nothing new. A swipe's Step Viewed can fire just
    // after the first flush — or its batch can still be in flight at
    // snapshot time — and a single snapshot then misses an event the SDK
    // did send. Each round is one flush plus a settle (~0.1 s); a slow
    // upload lands by the next round and shows up as growth, so no fixed
    // sleep is needed. Cap the drain so a chatty fake (autoplay) cannot
    // stall the suite; the check still reports what arrived.
    func trackCount() -> Int {
        world.network.logSnapshot(from: world.eventBaseline).filter { $0.endpoint == "track" }.count
    }
    var previous = -1
    for _ in 0..<8 {
        sdk.services?.analyticsService?.flush()
        await world.settle()
        let count = trackCount()
        if count == previous { break }
        previous = count
    }
    return world.network.logSnapshot(from: world.eventBaseline)
        .filter { $0.endpoint == "track" }
        .flatMap { entry -> [[String: Any]] in
            guard let body = entry.body as? [String: Any],
                  let list = body["events"] as? [[String: Any]]
            else { return [] }
            return list
        }
        .filter { ($0["event_name"] as? String) != "sdk_health" && world.isFromThisInstall($0) }
}

/// `{ call: trigger, campaignKey, cepCampaignId, accepted, state, outcome,
/// reason }` for every delivery (`outcome`/`reason` once it settled), plus
/// `{ call: setup|teardown|onScreenChanged|trackEvent, ... }` in call order.
@MainActor private func cepCalls(_ world: YamlWorld) -> [[String: Any]] {
    world.cep.calls + world.cep.deliveries.map {
        trigger($0.trigger, $0.presentation, signals: world.cep.signals[ObjectIdentifier($0.presentation)] ?? [])
    }
}

@MainActor private func trigger(
    _ payload: CEPTriggerPayload, _ presentation: any CampaignPresentation, signals: [String]
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
    var marks = signals
    out["completed"] = false
    switch outcome {
    case .dismissed(let reason, let completed):
        out["outcome"] = "dismissed"
        out["reason"] = reason.value
        out["completed"] = completed
        marks.append("dismissed")
    case .dropped(let reason, _):
        out["outcome"] = "dropped"
        out["reason"] = reason.value
        marks.append("dropped")
    case nil:
        break
    }
    out["signals"] = marks
    return out
}

/// `{ stage, reason, campaignKey, presentationId, screenName, severity,
/// extras: {...} }` for each record that carries a stage (the ones a
/// campaign creator may see). Never the free-text message.
@MainActor private func logRecords(_ world: YamlWorld) -> [[String: Any]] {
    world.logSink.records.map(record)
}

private func record(_ record: TimelineRecord) -> [String: Any] {
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
