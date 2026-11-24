import Foundation
@testable import DigiaEngage

/// Page & component capture: the debug switch, the capture profile, running a
/// capture and asserting the upload. Mirrors Flutter's
/// `test/yaml/handlers/capture.dart`; see `CAPTURE-COVERAGE-PLAN.md`.
let yamlCaptureHandlers: [String: YamlHandler] = [
    "setCaptureMode": { world, args in
        let enabled = args["enabled"] as? Bool ?? false
        if world.launched {
            SDKInstance.shared.setCaptureModeEnabled(enabled)
        } else {
            world.preLaunch.append { SDKInstance.shared.setCaptureModeEnabled(enabled) }
        }
    },
    "setCaptureProfile": { world, args in
        if args.isEmpty {
            throw YamlTestFailure(
                "setCaptureProfile checks nothing",
                expected: "includeText, includeMedia and/or includeStructure",
                line: world.step.line)
        }
        let apply: @MainActor () -> Void = {
            SDKInstance.shared.setCaptureProfile(
                includeText: args["includeText"] as? Bool,
                includeMedia: args["includeMedia"] as? Bool,
                includeStructure: args["includeStructure"] as? Bool)
        }
        if world.launched {
            apply()
        } else {
            world.preLaunch.append { apply() }
        }
    },
    "capturePage": capturePage,
    "assertCaptureStatus": assertCaptureStatus,
    "assertCaptureUpload": assertCaptureUpload,
]

/// Taps the debug camera: runs the capture flow now and records the status
/// message the SDK shows. A refused capture is a normal outcome, asserted
/// with `assertCaptureStatus` / `assertCaptureUpload`. A silent refusal
/// (e.g. capture mode off) publishes nothing: the test goes on with
/// whatever was recorded. A hung upload leaves the flow in flight: the test
/// goes on and `assertCaptureStatus` awaits it after `releaseApi`.
@MainActor private func capturePage(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let sdk = try world.sdk
    world.captureStatus = nil
    world.captureAwaiting = false
    // Uploads so far: the hold is detected when the flow's own request
    // arrives (not when the rule exists — the task still sleeps a second).
    func uploadCount() -> Int {
        world.network.logSnapshot(from: 0).filter { $0.endpoint == "recordPageCapture" }.count
    }
    let before = uploadCount()
    sdk.captureCurrentPage()
    if !sdk.captureInFlight {
        // Synchronous refusal (or silent): whatever was published is the answer.
        world.captureStatus = sdk.captureStatusMessage
        await world.settle()
        return
    }
    // The flow sleeps a second before uploading: wait for it to finish or hang.
    try await world.waitUntil("the capture to finish or hang", timeout: 20) {
        !SDKInstance.shared.captureInFlight || uploadCount() > before
    }
    if SDKInstance.shared.captureInFlight {
        // The upload is held: finished when releaseApi answers it.
        world.captureAwaiting = true
        await world.settle()
        return
    }
    world.captureStatus = SDKInstance.shared.captureStatusMessage
    await world.settle()
}

@MainActor private func assertCaptureStatus(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let want = args["status"]
    let contains = args["contains"]
    if want == nil && contains == nil {
        throw YamlTestFailure(
            "assertCaptureStatus checks nothing",
            expected: "status and/or contains",
            line: world.step.line)
    }
    if world.captureStatus == nil && world.captureAwaiting {
        // A hung upload, now released: await the flow's terminal status.
        try await world.waitUntil("the released capture to finish", timeout: 20) {
            !SDKInstance.shared.captureInFlight
        }
        world.captureStatus = SDKInstance.shared.captureStatusMessage
        world.captureAwaiting = false
        await world.settle()
    }
    guard let got = world.captureStatus else {
        throw YamlTestFailure(
            "no capture has run yet",
            expected: "capturePage before assertCaptureStatus",
            line: world.step.line)
    }
    var problems: [String] = []
    if let want, "\(want)" != got {
        problems.append("status: expected \(YamlMatch.json(want)), got \(YamlMatch.json(got))")
    }
    if let contains, !got.contains("\(contains)") {
        problems.append("status does not contain \"\(contains)\": \(got)")
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(
        problems.joined(separator: "\n           "),
        expected: "the capture status to match",
        actual: got,
        line: world.step.line)
}

/// The `recordPageCapture` uploads since the `clearState` launch, read as the
/// decoded `capture` JSON the fake logged (see `executeMultipart`).
/// `containsNodes` items are partial node matches, each of which must fit at
/// least one uploaded node; `absentNodeTypes` names node types no uploaded
/// node may have.
@MainActor private func assertCaptureUpload(_ world: YamlWorld, _ args: [String: Any]) async throws {
    if args.isEmpty {
        throw YamlTestFailure(
            "assertCaptureUpload checks nothing",
            expected: "count and/or fields of the latest upload",
            line: world.step.line)
    }
    let sent = world.network.logSnapshot(from: world.apiBaseline)
        .filter { $0.endpoint == "recordPageCapture" }
        .map { $0.body }
    var problems: [String] = []
    if let count = args["count"] as? Int, sent.count != count {
        problems.append("count: expected \(count), got \(sent.count)")
    }
    var fields = args
    fields.removeValue(forKey: "count")
    if !fields.isEmpty {
        guard let body = sent.last as? [String: Any] else {
            throw YamlTestFailure(
                "no page capture was uploaded",
                expected: "an upload matching \(YamlMatch.json(fields))",
                line: world.step.line)
        }
        if let pageKey = fields["pageKey"] as? String, body["pageKey"] as? String != pageKey {
            problems.append("pageKey: expected \(pageKey), got \(YamlMatch.json(body["pageKey"]))")
        }
        if let profile = fields["profile"] as? [String: Any] {
            // Written with the YAML profile names; the wire uses the stack names.
            var want: [String: Any] = [:]
            for (key, value) in profile {
                switch key {
                case "includeText": want["includeText"] = value
                case "includeMedia": want["includeImagesAndMedia"] = value
                case "includeStructure": want["includeOtherStructuralNodes"] = value
                default:
                    throw YamlTestFailure(
                        "assertCaptureUpload: unknown profile key \"\(key)\"",
                        expected: "includeText, includeMedia, includeStructure",
                        line: world.step.line)
                }
            }
            if !captureContains(body["captureProfile"], want) {
                problems.append(
                    "captureProfile: expected to contain \(YamlMatch.json(want)), "
                        + "got \(YamlMatch.json(body["captureProfile"]))")
            }
        }
        let nodes = body["nodes"]
        if fields["containsNodes"] != nil || fields["absentNodeTypes"] != nil {
            guard let list = nodes as? [Any] else {
                problems.append("nodes: expected a list, got \(YamlMatch.json(nodes))")
                throw YamlTestFailure(
                    problems.joined(separator: "\n           "),
                    expected: "the page capture uploads to match",
                    actual: uploadList(sent),
                    line: world.step.line)
            }
            for want in (fields["containsNodes"] as? [Any] ?? []) {
                if (want as? [String: Any]) == nil
                    || !list.contains(where: { captureContains($0, want) })
                {
                    problems.append(
                        "containsNodes: nothing matches \(YamlMatch.json(want)) "
                            + "among \(list.count) nodes")
                }
            }
            for type in (fields["absentNodeTypes"] as? [Any] ?? []) {
                let hit = list.filter {
                    ($0 as? [String: Any])?["nodeType"] as? String == "\(type)"
                }.count
                if hit > 0 {
                    problems.append("absentNodeTypes: nodeType \"\(type)\" was uploaded (\(hit)x)")
                }
            }
        }
        for key in fields.keys where !["pageKey", "profile", "containsNodes", "absentNodeTypes"].contains(key) {
            throw YamlTestFailure(
                "assertCaptureUpload: unknown argument \"\(key)\"",
                expected: "count, pageKey, profile, containsNodes, absentNodeTypes",
                line: world.step.line)
        }
    }
    if problems.isEmpty { return }
    throw YamlTestFailure(
        problems.joined(separator: "\n           "),
        expected: "the page capture uploads to match",
        actual: uploadList(sent),
        line: world.step.line)
}

/// Every key of [want] is in [got] with a matching value, recursively; a key
/// wanted as null must be absent (or null). Value matchers allowed.
private func captureContains(_ got: Any?, _ want: Any?) -> Bool {
    if let wantMap = want as? [String: Any] {
        guard let gotMap = got as? [String: Any] else { return false }
        if let matcher = YamlMatch.valueMatcher(wantMap) {
            return YamlMatch.matchValue(matcher, got, present: true)
        }
        return wantMap.allSatisfy { key, value in
            if value is NSNull { return gotMap[key] == nil || gotMap[key] is NSNull }
            if let matcher = YamlMatch.valueMatcher(value) {
                return YamlMatch.matchValue(matcher, gotMap[key], present: gotMap.keys.contains(key))
            }
            return gotMap.keys.contains(key) && captureContains(gotMap[key], value)
        }
    }
    if let wantList = want as? [Any] {
        guard let gotList = got as? [Any], gotList.count == wantList.count else { return false }
        return zip(gotList, wantList).allSatisfy { captureContains($0, $1) }
    }
    return YamlMatch.matches(got, want)
}

private func uploadList(_ sent: [Any?]) -> String {
    "\(sent.count) uploads:\n" + sent.map { "    \(YamlMatch.json($0))" }.joined(separator: "\n")
}
