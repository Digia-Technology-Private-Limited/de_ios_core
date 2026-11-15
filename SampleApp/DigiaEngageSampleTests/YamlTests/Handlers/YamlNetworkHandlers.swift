import Foundation
@testable import DigiaEngage

/// The fake network: per-endpoint answers, one-shot answers, held requests
/// and request assertions. Mirrors `handlers/network.dart`.
let yamlNetworkHandlers: [String: YamlHandler] = [
    "mockApi": { try await mock($0, $1, once: false) },
    "mockApiOnce": { try await mock($0, $1, once: true) },
    "releaseApi": release,
    "assertApi": assertApi,
]

@MainActor private func mock(_ world: YamlWorld, _ args: [String: Any], once: Bool) async throws {
    let name = once ? "mockApiOnce" : "mockApi"
    let endpoint = try endpointName(world, args["endpoint"])
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
    if hang && endpoint == "getCampaigns" {
        // The boot and the relaunch await the campaign fetch.
        throw YamlTestFailure(
            "hang is not supported on getCampaigns",
            expected: "hang on another endpoint",
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
    await world.settle()
}

@MainActor private func assertApi(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let endpoint = try endpointName(world, args["endpoint"])
    let count = args["count"] as? Int
    let lastBody = args["lastBody"]
    if count == nil && lastBody == nil {
        throw YamlTestFailure(
            "assertApi checks nothing",
            expected: "count and/or lastBody",
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
    if let lastBody {
        guard let last = sent.last else {
            throw YamlTestFailure(
                "\(endpoint) was never requested",
                expected: "a request with body \(YamlMatch.json(lastBody))",
                line: world.step.line)
        }
        if !YamlMatch.matches(last.body, lastBody) {
            throw YamlTestFailure(
                "\(endpoint) last request body",
                expected: "to contain \(YamlMatch.json(lastBody))",
                actual: YamlMatch.json(last.body),
                line: world.step.line)
        }
    }
}

@MainActor private func endpointName(_ world: YamlWorld, _ name: Any?) throws -> String {
    if let name = name as? String,
       YamlNetworkFake.paths[name] != nil || name == "userContext"
    {
        return name
    }
    throw YamlTestFailure(
        "unknown endpoint \"\(name as Any)\"",
        expected: (YamlNetworkFake.paths.keys.sorted() + ["userContext"]).joined(separator: ", "),
        line: world.step.line)
}

@MainActor private func campaigns(_ world: YamlWorld, _ raw: Any?) throws -> [[String: Any]] {
    let body = try world.json(raw)
    let items: [Any]
    if let list = body as? [Any] {
        items = list
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
        body = parsed
    } else {
        body = "{}"
    }
    return YamlNetworkFake.Rule(status: args["status"] as? Int ?? 200, body: body)
}
