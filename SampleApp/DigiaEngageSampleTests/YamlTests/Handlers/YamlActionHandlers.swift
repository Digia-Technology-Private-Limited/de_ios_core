import Foundation
@testable import DigiaEngage

/// The host-app side of the authored actions: what the SDK asked the phone
/// (clipboard, share sheet, review prompt) or handed the app (customKV) to do.
/// Clipboard, share and review come from the `RecordingPlatform` the world
/// already swaps in as `ActionPlatform.current`; customKV is recorded by the
/// handler `bootForTest` installs. Mirrors `handlers/actions.dart`.
let yamlActionHandlers: [String: YamlHandler] = [
    "assertClipboard": assertClipboard,
    "assertCustomKV": assertCustomKV,
    "assertShare": assertShare,
    "assertReview": assertReview,
]

/// The system pasteboard holds the authored text.
@MainActor private func assertClipboard(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let want = args["text"] as? String else {
        throw YamlTestFailure("assertClipboard needs text",
                              expected: "text: <string>", line: world.step.line)
    }
    await world.settle()
    let copied = world.platform.copied
    if !copied.contains(want) {
        throw YamlTestFailure("clipboard does not hold \"\(want)\"",
                              expected: "a copyToClipboard of \"\(want)\" before this step",
                              actual: copied.isEmpty ? "nothing copied" : "copied: \(copied)",
                              line: world.step.line)
    }
}

/// `contains` / `notContains` (partial match per item) and `exactly` over the
/// customKV payloads the host handler received, in order.
@MainActor private func assertCustomKV(_ world: YamlWorld, _ args: [String: Any]) async throws {
    if args.isEmpty {
        throw YamlTestFailure("customKV payloads: checks nothing",
                              expected: "contains, notContains or exactly", line: world.step.line)
    }
    await world.settle()
    let got = world.customKVReceived
    var problems: [String] = []
    for want in args["contains"] as? [Any] ?? [] {
        if !got.contains(where: { YamlMatch.matches($0, want) }) {
            problems.append("contains: nothing matches \(YamlMatch.json(want))")
        }
    }
    for want in args["notContains"] as? [Any] ?? [] {
        if let hit = got.first(where: { YamlMatch.matches($0, want) }) {
            problems.append("notContains: \(YamlMatch.json(want)) matched \(YamlMatch.json(hit))")
        }
    }
    if let want = args["exactly"] as? [Any] {
        let same = want.count == got.count && zip(want, got).allSatisfy { YamlMatch.matches($1, $0) }
        if !same { problems.append("exactly: expected \(YamlMatch.json(want))") }
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(problems.joined(separator: "\n           "),
                          expected: "the customKV payloads to match",
                          actual: "\(got.count) payloads: \(YamlMatch.json(got))", line: world.step.line)
}

/// `contains` / `notContains` (whole strings) and `exactly` over the texts
/// the SDK asked the share sheet to share, in order.
@MainActor private func assertShare(_ world: YamlWorld, _ args: [String: Any]) async throws {
    if args.isEmpty {
        throw YamlTestFailure("shares: checks nothing",
                              expected: "contains, notContains or exactly", line: world.step.line)
    }
    await world.settle()
    let got = world.platform.shared
    var problems: [String] = []
    for want in args["contains"] as? [Any] ?? [] where !got.contains("\(want)") {
        problems.append("contains: \(want) not shared")
    }
    for want in args["notContains"] as? [Any] ?? [] where got.contains("\(want)") {
        problems.append("notContains: \(want) shared")
    }
    if let want = args["exactly"] as? [Any], want.map({ "\($0)" }) != got {
        problems.append("exactly: expected \(want.map { "\($0)" })")
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(problems.joined(separator: "\n           "),
                          expected: "the shares to match",
                          actual: "\(got.count) shares: \(got)", line: world.step.line)
}

/// The review prompt was requested `count` times.
@MainActor private func assertReview(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let want = args["count"] as? Int else {
        throw YamlTestFailure("assertReview needs count",
                              expected: "count: <int>", line: world.step.line)
    }
    await world.settle()
    let got = world.platform.reviewRequests
    if got != want {
        throw YamlTestFailure("review requested \(got) times",
                              expected: "\(want)", actual: "\(got) requests",
                              line: world.step.line)
    }
}
