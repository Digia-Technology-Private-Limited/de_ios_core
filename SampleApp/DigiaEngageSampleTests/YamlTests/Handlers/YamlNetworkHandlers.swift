import Foundation
@testable import DigiaEngage

/// The fake network: per-endpoint answers, one-shot answers, held requests
/// and request assertions. Mirrors `handlers/network.dart`.
let yamlNetworkHandlers: [String: YamlHandler] = [
    "mockApi": { try await mock($0, $1, once: false) },
    "mockApiOnce": { try await mock($0, $1, once: true) },
    "releaseApi": release,
    "assertApi": assertApi,
    "assertSurveySubmission": assertSurveySubmission,
    "mockServerTime": mockServerTime,
    "mockMedia": mockMedia,
]

/// Serves the campaign-bundle response with the X-Digia-Server-Time-Ms header
/// the backend sends, so bundle parsing that needs the server clock behaves
/// as in production. Callable before launchApp.
@MainActor private func mockServerTime(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let ms = args["epochMs"] as? Int else {
        throw YamlTestFailure(
            "mockServerTime needs epochMs",
            expected: "mockServerTime: { epochMs: 1893456000000 }",
            line: world.step.line)
    }
    world.network.serverTimeMs = ms
}

/// Missing Test Kit media fails as the server would instead of a stand-in
/// (failMissing), so a campaign whose media cannot be had is never shown.
/// Callable before launchApp. On iOS asset URLs resolve to files on disk, so
/// a missing asset already fails with no interception to configure.
@MainActor private func mockMedia(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard args["failMissing"] as? Bool == true else {
        throw YamlTestFailure(
            "mockMedia: nothing to do",
            expected: "mockMedia: { failMissing: true }",
            line: world.step.line)
    }
}

@MainActor private func mock(_ world: YamlWorld, _ args: [String: Any], once: Bool) async throws {
    let name = once ? "mockApiOnce" : "mockApi"
    var args = args
    let endpoint = try endpointName(world, args["endpoint"])
    if let items = args["campaigns"] {
        if endpoint != "getCampaigns" || once || args["body"] != nil {
            throw YamlTestFailure(
                "campaigns is for mockApi getCampaigns, without body",
                expected: "mockApi: { endpoint: getCampaigns, campaigns: [...] }",
                line: world.step.line)
        }
        args["body"] = try composeCampaigns(world, items as? [Any] ?? [])
    }
    let hang = args["hang"] as? Bool ?? false
    let fail = args["fail"]
    let hasBody = args["body"] != nil
    if !hang && fail == nil && !hasBody && args["status"] == nil {
        throw YamlTestFailure(
            "\(name) says nothing about the answer",
            expected: "body, fail or hang",
            line: world.step.line)
    }
    if hang && (fail != nil || hasBody) {
        throw YamlTestFailure(
            "hang cannot be combined with body or fail",
            expected: "one of body, fail, hang",
            line: world.step.line)
    }
    // A plain campaign body keeps the launch path: the SDK is served these.
    if !once, endpoint == "getCampaigns", hasBody, fail == nil, args["status"] == nil {
        world.campaigns = try campaigns(world, args["body"])
        world.network.removeRule(for: endpoint)
        return
    }
    let rule = hang ? YamlNetworkFake.Rule(hang: true)
        : try reply(world, endpoint: endpoint, args: args)
    if once {
        world.network.addOnce(rule, for: endpoint)
    } else {
        world.network.setRule(rule, for: endpoint)
    }
}

/// Answers every request held on the endpoint, then stops holding it.
@MainActor private func release(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let endpoint = try endpointName(world, args["endpoint"])
    let answered = args["body"] != nil || args["fail"] != nil
    let rule = answered ? try reply(world, endpoint: endpoint, args: args)
        : nil as YamlNetworkFake.Rule?
    if !world.network.release(endpoint: endpoint, with: rule) {
        throw YamlTestFailure(
            "no request is held on \(endpoint)",
            expected: "a mockApi with hang: true and a request made to it",
            line: world.step.line)
    }
    if endpoint == "getCampaigns", world.launched {
        // The held fetch now settles the SDK, as the launch would have.
        try await world.waitUntil("the SDK to settle", timeout: 10) {
            SDKInstance.shared.sdkState != .initializing
        }
    }
    await world.settle()
}

@MainActor private func assertApi(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let endpoint = try endpointName(world, args["endpoint"])
    let count = args["count"] as? Int
    let lastBody = args["lastBody"]
    let lastHeaders = args["lastHeaders"] as? [String: Any]
    let contains = args["contains"] as? [Any]
    if count == nil && lastBody == nil && lastHeaders == nil && contains == nil {
        throw YamlTestFailure(
            "assertApi checks nothing",
            expected: "count, lastBody, lastHeaders and/or contains",
            line: world.step.line)
    }
    let sent = world.network.logSnapshot(from: world.apiBaseline)
        .filter { $0.endpoint == endpoint }
    if let count, sent.count != count {
        throw YamlTestFailure(
            "\(endpoint) request count",
            expected: "\(count)",
            actual: "\(sent.count)",
            line: world.step.line)
    }
    if let contains {
        guard !sent.isEmpty else {
            throw YamlTestFailure(
                "\(endpoint) was never requested",
                expected: "requests with bodies \(YamlMatch.json(contains))",
                line: world.step.line)
        }
        for want in contains {
            if !sent.contains(where: { bodyContains($0.body, want) }) {
                throw YamlTestFailure(
                    "\(endpoint) request bodies",
                    expected: "one to contain \(YamlMatch.json(want))",
                    actual: "[\(sent.map { YamlMatch.json($0.body) }.joined(separator: ", "))]",
                    line: world.step.line)
            }
        }
    }
    if let lastBody {
        guard let last = sent.last else {
            throw YamlTestFailure(
                "\(endpoint) was never requested",
                expected: "a request with body \(YamlMatch.json(lastBody))",
                line: world.step.line)
        }
        if !bodyContains(last.body, lastBody) {
            throw YamlTestFailure(
                "\(endpoint) last request body",
                expected: "to contain \(YamlMatch.json(lastBody))",
                actual: YamlMatch.json(last.body),
                line: world.step.line)
        }
    }
    if let lastHeaders {
        guard let last = sent.last else {
            throw YamlTestFailure(
                "\(endpoint) was never requested",
                expected: "a request with headers \(lastHeaders)",
                line: world.step.line)
        }
        for (name, value) in lastHeaders {
            let got = last.headers[name.lowercased()]
            if let matcher = YamlMatch.valueMatcher(value) {
                if YamlMatch.matchValue(matcher, got, present: got != nil) { continue }
            } else if got == "\(value)" {
                continue
            }
            throw YamlTestFailure(
                "\(endpoint) last request headers",
                expected: "\(name): \(value)",
                actual: "\(last.headers)",
                line: world.step.line)
        }
    }
}

@MainActor private func endpointName(_ world: YamlWorld, _ name: Any?) throws -> String {
    if let name = name as? String, YamlNetworkFake.paths[name] != nil {
        return name
    }
    throw YamlTestFailure(
        "unknown endpoint \"\(name as Any)\"",
        expected: YamlNetworkFake.paths.keys.sorted().joined(separator: ", "),
        line: world.step.line)
}

/// Every key of [want] is in [have] with a matching value, recursively. A
/// key wanted as null must be absent (or null). Mirrors `_contains`.
private func bodyContains(_ have: Any?, _ want: Any?) -> Bool {
    if let wantMap = want as? [String: Any] {
        guard let haveMap = have as? [String: Any] else { return false }
        if let matcher = YamlMatch.valueMatcher(wantMap) {
            return YamlMatch.matchValue(matcher, have, present: true)
        }
        return wantMap.allSatisfy { key, value in
            if value is NSNull { return haveMap[key] == nil || haveMap[key] is NSNull }
            if let matcher = YamlMatch.valueMatcher(value) {
                return YamlMatch.matchValue(matcher, haveMap[key], present: haveMap.keys.contains(key))
            }
            return haveMap.keys.contains(key) && bodyContains(haveMap[key], value)
        }
    }
    if let wantList = want as? [Any] {
        guard let haveList = have as? [Any], haveList.count == wantList.count else { return false }
        return zip(haveList, wantList).allSatisfy { bodyContains($0, $1) }
    }
    return YamlMatch.matches(have, want)
}

/// `mockApi getCampaigns campaigns:` items built from the stock templates in
/// `fixtures/campaigns/dmc/` (see commands.yaml). Mirrors `composeCampaigns`.
@MainActor private func composeCampaigns(_ world: YamlWorld, _ items: [Any]) throws -> [[String: Any]] {
    guard let root = YamlDiscovery.root() else {
        throw YamlTestFailure("Test Kit sdk-tests not found", line: world.step.line)
    }
    let known: Set<String> = [
        "key", "template", "slot", "text", "rule", "priority", "frequency",
        "audienceGated", "targetScreens", "contextVariables", "fixture", "patch",
    ]
    return try items.map { raw in
        guard let item = raw as? [String: Any],
              item["key"] is String || item["fixture"] is String
        else {
            throw YamlTestFailure(
                "campaigns: an item needs a key (or a fixture)",
                expected: "{ key: welcome, rule: {...} }",
                actual: "\(raw)",
                line: world.step.line)
        }
        for name in item.keys where !known.contains(name) {
            throw YamlTestFailure(
                "campaigns: unknown item key \"\(name)\"",
                expected: known.sorted().joined(separator: ", "),
                line: world.step.line)
        }
        var campaign: [String: Any]
        if let fixture = item["fixture"] as? String {
            // A campaign file used instead of a stock template; key renames it.
            guard let loaded = try world.json(fixture) as? [String: Any] else {
                throw YamlTestFailure(
                    "campaigns: fixture is not one campaign object",
                    expected: "a JSON object in \(fixture)",
                    line: world.step.line)
            }
            campaign = loaded
            if let key = item["key"] as? String { campaign["campaignKey"] = key }
        } else {
        let key = item["key"] as! String
        let template = item["template"] as? String ?? "overlay"
        let file: String
        switch template {
        case "overlay": file = "_overlay.json"
        case "inline": file = "_inline_banner.json"
        default:
            throw YamlTestFailure(
                "campaigns: unknown template \"\(template)\"",
                expected: "overlay or inline",
                line: world.step.line)
        }
        let slot = item["slot"] as? String
        if template == "inline" && slot == nil {
            throw YamlTestFailure("campaigns: inline \"\(key)\" needs a slot", line: world.step.line)
        }
        let text = item["text"].map { "\($0)" } ?? key
        let url = root.appendingPathComponent("fixtures/campaigns/dmc/\(file)")
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data)
        else {
            throw YamlTestFailure("campaigns: template not readable", expected: url.path, line: world.step.line)
        }
        func fill(_ value: Any) -> Any {
            if let string = value as? String {
                return string.replacingOccurrences(of: "__KEY__", with: key)
                    .replacingOccurrences(of: "__TEXT__", with: text)
                    .replacingOccurrences(of: "__SLOT__", with: slot ?? "")
            }
            if let map = value as? [String: Any] { return map.mapValues(fill) }
            if let list = value as? [Any] { return list.map(fill) }
            return value
        }
        campaign = fill(parsed) as? [String: Any] ?? [:]
        }
        if item.keys.contains("rule") { campaign["rule"] = item["rule"] ?? NSNull() }
        if item.keys.contains("priority") {
            guard var rule = campaign["rule"] as? [String: Any] else {
                throw YamlTestFailure("campaigns: priority needs a rule map", line: world.step.line)
            }
            rule["priority"] = item["priority"] ?? NSNull()
            campaign["rule"] = rule
        }
        if item.keys.contains("frequency") { campaign["frequency"] = item["frequency"] ?? NSNull() }
        if let gated = item["audienceGated"] { campaign["audienceGated"] = gated }
        if let names = item["targetScreens"] as? [Any] {
            campaign["targetScreenNames"] = ["names": names]
        }
        if let vars = item["contextVariables"] as? [Any],
           var templateConfig = campaign["templateConfig"] as? [String: Any]
        {
            templateConfig["contextVariables"] = vars
            campaign["templateConfig"] = templateConfig
        }
        if let ops = item["patch"] {
            guard let list = ops as? [Any] else {
                throw YamlTestFailure("campaigns: patch must be a list", line: world.step.line)
            }
            campaign = try applyJsonPatch(world, campaign, list)
        }
        return campaign
    }
}

/// RFC 6902 add / remove / replace over [doc]; a missing path is a step
/// error. Mirrors `_applyPatch` in the Flutter driver.
@MainActor private func applyJsonPatch(
    _ world: YamlWorld, _ doc: [String: Any], _ ops: [Any]
) throws -> [String: Any] {
    var root: Any = doc
    for raw in ops {
        guard let op = raw as? [String: Any], let kind = op["op"] as? String,
              let path = op["path"] as? String, path.hasPrefix("/")
        else {
            throw YamlTestFailure(
                "campaigns: bad patch op", expected: "{ op, path: /json/pointer, value }",
                actual: "\(raw)", line: world.step.line)
        }
        guard ["add", "remove", "replace"].contains(kind) else {
            throw YamlTestFailure(
                "campaigns: patch op \"\(kind)\" is not add, remove or replace",
                line: world.step.line)
        }
        let tokens = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }
        // Patched-in paths behave like fixture content: resolve the TestKit
        // asset placeholder the same way fixture files are resolved.
        let value: Any = {
            guard let text = op["value"] as? String,
                  let workspace = FixtureLoader.workspaceURL() else {
                return op["value"] ?? NSNull()
            }
            return FixtureLoader.resolveAssetOrigin(in: text, workspaceUrl: workspace)
        }()
        func bad() -> YamlTestFailure {
            YamlTestFailure(
                "campaigns: patch path \(path) does not exist", expected: "an existing path for \(kind)",
                line: world.step.line)
        }
        func apply(_ node: Any, _ rest: ArraySlice<String>) throws -> Any? {
            let token = rest.first!
            let last = rest.count == 1
            if var map = node as? [String: Any] {
                if last {
                    switch kind {
                    case "add": map[token] = value
                    case "replace":
                        guard map[token] != nil else { throw bad() }
                        map[token] = value
                    default:
                        guard map.removeValue(forKey: token) != nil else { throw bad() }
                    }
                    return map
                }
                guard let child = map[token] else { throw bad() }
                map[token] = try apply(child, rest.dropFirst())
                return map
            }
            if var list = node as? [Any] {
                if last && kind == "add" && token == "-" {
                    list.append(value)
                    return list
                }
                guard let index = Int(token), index >= 0,
                      index < list.count || (last && kind == "add" && index == list.count)
                else { throw bad() }
                if last {
                    switch kind {
                    case "add": list.insert(value, at: index)
                    case "replace": list[index] = value
                    default: list.remove(at: index)
                    }
                    return list
                }
                list[index] = try apply(list[index], rest.dropFirst()) as Any
                return list
            }
            throw bad()
        }
        guard !tokens.isEmpty else { throw bad() }
        root = try apply(root, ArraySlice(tokens)) as Any
    }
    return root as? [String: Any] ?? doc
}

@MainActor private func campaigns(_ world: YamlWorld, _ raw: Any?) throws -> [[String: Any]] {
    let body = try world.json(raw)
    let items: [Any]
    if let list = body as? [Any] {
        // A list of campaign files, served in order (each one campaign or a list).
        items = try list.flatMap { item -> [Any] in
            guard let path = item as? String, path.hasSuffix(".json") else { return [item] }
            let loaded = try world.json(path)
            return (loaded as? [Any]) ?? [loaded as Any]
        }
    } else if let map = body as? [String: Any] {
        items = [map]
    } else {
        throw YamlTestFailure(
            "getCampaigns needs a body",
            expected: "a JSON file path, a campaign map or a list of campaigns",
            actual: "\(body as Any)",
            line: world.step.line)
    }
    return items.map { ($0 as? [String: Any]) ?? [:] }
}

/// The answer a `body` / `status` / `fail` combination stands for.
/// `getCampaigns` takes campaigns and wraps them as the bundle endpoint does.
@MainActor private func reply(
    _ world: YamlWorld, endpoint: String, args: [String: Any]
) throws -> YamlNetworkFake.Rule {
    if let fail = args["fail"] {
        if fail as? String == "network" {
            return YamlNetworkFake.Rule(networkError: true)
        }
        let status: Int? = {
            if let code = fail as? Int { return code }
            return Int("\(fail)")
        }()
        guard let status else {
            throw YamlTestFailure(
                "fail is not a status code or \"network\"",
                expected: "e.g. 503 or network",
                actual: "\(fail)",
                line: world.step.line)
        }
        return YamlNetworkFake.Rule(status: status, body: "{}")
    }
    let raw = args["body"]
    let body: Any?
    if endpoint == "getCampaigns", raw != nil {
        body = ["data": ["response": ["campaigns": try campaigns(world, raw)]]]
    } else if let parsed = try world.json(raw) {
        if endpoint == "userContext", let inner = parsed as? [String: Any] {
            // The inner response, wrapped as every Engage endpoint answers.
            body = ["isSuccess": true, "data": ["response": inner]]
        } else {
            body = parsed
        }
    } else {
        body = "{}"
    }
    return YamlNetworkFake.Rule(status: args["status"] as? Int ?? 200, body: body)
}

/// The survey submissions since the clearState launch, checked as
/// maestro/scripts/assertSurveySubmission.js does (see commands.yaml).
/// Mirrors `_assertSubmission` in the Flutter driver.
@MainActor private func assertSurveySubmission(_ world: YamlWorld, _ args: [String: Any]) async throws {
    if args.isEmpty {
        throw YamlTestFailure(
            "assertSurveySubmission checks nothing",
            expected: "count and/or fields of the latest submission",
            line: world.step.line)
    }
    // The POST is fired off a detached task; let it reach the fake.
    await world.settle()
    let sent = world.network.logSnapshot(from: world.apiBaseline)
        .filter { $0.endpoint == "surveySubmission" }
        .map { $0.body }
    var problems: [String] = []
    if let count = args["count"] as? Int, sent.count != count {
        problems.append("count: expected \(count), got \(sent.count)")
    }
    var fields = args
    fields.removeValue(forKey: "count")
    if !fields.isEmpty {
        guard let last = sent.last else {
            throw YamlTestFailure(
                "no survey submission was sent",
                expected: "a submission matching \(YamlMatch.json(fields))",
                line: world.step.line)
        }
        guard let body = last as? [String: Any] else {
            throw YamlTestFailure(
                "the latest submission body is not a JSON object",
                actual: "\(last as Any)", line: world.step.line)
        }
        checkEnvelope(body, &problems)
        let payload = body["payload"] as? [String: Any] ?? [:]
        let completion = payload["completion"] as? [String: Any] ?? [:]
        let computed = body["computed"] as? [String: Any] ?? [:]
        func same(_ what: String, _ got: Any?, _ want: Any?) {
            if !bodyContains(got, want) {
                problems.append("\(what): expected \(YamlMatch.json(want)), got \(YamlMatch.json(got))")
            }
        }
        if let key = args["campaign"] as? String {
            if let served = world.campaigns.first(where: { $0["campaignKey"] as? String == key }) {
                same("campaignId", body["campaignId"], served["id"])
            } else {
                problems.append("campaign: \"\(key)\" is not a served campaign")
            }
        }
        if args.keys.contains("answeredCount") {
            same("answeredCount", completion["answeredCount"], args["answeredCount"])
        }
        if args.keys.contains("totalCount") {
            same("totalCount", completion["totalCount"], args["totalCount"])
        }
        for (name, map) in [("npsBucket", computed), ("userId", body)] where args.keys.contains(name) {
            let want = args[name]
            if want == nil || want is NSNull {
                if let got = map[name], !(got is NSNull) {
                    problems.append("\(name): expected none, got \(YamlMatch.json(got))")
                }
            } else {
                same(name, map[name], want)
            }
        }
        if args.keys.contains("durationMs") {
            same("durationMs", computed["durationMs"], args["durationMs"])
        }
        if let want = args["responses"] as? [Any] {
            let got = payload["responses"] as? [Any] ?? []
            if got.count != want.count {
                problems.append("responses: expected \(want.count), got \(got.count): \(YamlMatch.json(got))")
            } else {
                let known: Set<String> = ["blockId", "blockType", "title", "value", "valueLabel"]
                for (i, pair) in zip(got, want).enumerated() {
                    guard let g = pair.0 as? [String: Any], let w = pair.1 as? [String: Any] else {
                        problems.append("responses[\(i)]: not an object")
                        continue
                    }
                    for (key, value) in w {
                        guard known.contains(key) else {
                            throw YamlTestFailure(
                                "responses: unknown key \"\(key)\"",
                                expected: known.sorted().joined(separator: ", "),
                                line: world.step.line)
                        }
                        let ok: Bool
                        if value is NSNull {
                            ok = g[key] == nil || g[key] is NSNull
                        } else if let list = value as? [Any] {
                            ok = (g[key] as? [Any]).map { sameSet($0, list) } ?? false
                        } else if let matcher = YamlMatch.valueMatcher(value) {
                            ok = YamlMatch.matchValue(matcher, g[key], present: g.keys.contains(key))
                        } else {
                            ok = g.keys.contains(key) && bodyContains(g[key], value)
                        }
                        if !ok {
                            problems.append("responses[\(i)].\(key): expected "
                                + (value is NSNull ? "absent" : YamlMatch.json(value))
                                + ", got \(YamlMatch.json(g[key]))")
                        }
                    }
                }
            }
        }
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(
        problems.joined(separator: "\n           "),
        expected: "the survey submissions to match",
        actual: "\(sent.count) submissions:\n"
            + sent.map { "    \(YamlMatch.json($0))" }.joined(separator: "\n"),
        line: world.step.line)
}

/// The stable envelope every submission carries (survey-submission.md).
private func checkEnvelope(_ body: [String: Any], _ problems: inout [String]) {
    if body["submissionType"] as? String != "survey" {
        problems.append("submissionType: expected survey, got \(body["submissionType"] ?? "none")")
    }
    if (body["submissionKey"] as? String)?.isEmpty ?? true {
        problems.append("submissionKey: expected a non-empty string, got \(body["submissionKey"] ?? "none")")
    }
    let at = body["occurredAt"] as? String ?? ""
    let iso = ISO8601DateFormatter()
    let isoFraction = ISO8601DateFormatter()
    isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if iso.date(from: at) == nil && isoFraction.date(from: at) == nil {
        problems.append("occurredAt: expected an ISO-8601 time, got \(at)")
    }
    if (body["payload"] as? [String: Any])?["templateVersion"] as? String != "v1" {
        problems.append("payload.templateVersion: expected v1")
    }
    let duration = ((body["computed"] as? [String: Any])?["durationMs"] as? NSNumber)?.doubleValue
    if duration == nil || duration! < 0 {
        problems.append("computed.durationMs: expected a number >= 0")
    }
}

/// [got] and [want] hold the same items, in any order.
private func sameSet(_ got: [Any], _ want: [Any]) -> Bool {
    got.count == want.count
        && want.allSatisfy { w in got.contains { bodyContains($0, w) } }
        && got.allSatisfy { g in want.contains { bodyContains(g, $0) } }
}
