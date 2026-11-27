import Foundation
@testable import DigiaEngage

/// Boots the SDK and fires the CEP. Mirrors `handlers/core.dart`.
let yamlCoreHandlers: [String: YamlHandler] = [
    "launchApp": launchApp,
    "triggerCep": triggerCep,
    "triggerCeps": triggerCeps,
    "triggerAndCancel": triggerAndCancel,
    "liveTest": liveTest,
    "cancelCep": cancelCep,
    "retryInitialize": retryInitialize,
    "seedStorage": seedStorage,
]

/// Boots the SDK serving what `mockApi: getCampaigns` set, under a plain
/// host screen. A second launch without `clearState` is a relaunch over the
/// same storage.
@MainActor private func launchApp(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let host = args["host"] as? String ?? "plain"
    if host != "plain" && host != "phone" && host != "tablet" && host != "none" {
        throw YamlTestFailure(
            "unknown host \"\(host)\"",
            expected: "plain, phone, tablet or none (no DigiaHost: nothing draws the SDK)",
            line: world.step.line)
    }
    let device = args["device"] as? [String: Any]
    let known: Set<String> = ["platform", "osVersion", "appVersion", "locale"]
    for key in device?.keys.sorted() ?? [] where !known.contains(key) {
        throw YamlTestFailure(
            "launchApp device: unknown key \"\(key)\"",
            expected: known.sorted().joined(separator: ", "),
            line: world.step.line)
    }
    try await world.bootForTest(
        clearState: args["clearState"] as? Bool ?? false,
        mountPhone: host == "phone",
        mountTablet: host == "tablet",
        mountHost: host != "none",
        background: args["background"] as? Bool ?? false,
        waitForReady: args["waitForReady"] as? Bool ?? true,
        device: device,
        withCep: args["cep"] as? Bool ?? true,
        wrapper: args["wrapper"] as? String)
}

/// The host calls initialize again in the same process, as after a failed
/// fetch, and waits until the new fetch settles (or is held by a hang).
@MainActor private func retryInitialize(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let sdk = try world.sdk
    let before = world.network.logSnapshot(from: 0).filter { $0.endpoint == "getCampaigns" }.count
    var finished = false
    Task { @MainActor in
        try? await Digia.initialize(DigiaConfig(
            apiKey: "test-api-key", fontFamily: GoldenFonts.family))
        finished = true
    }
    // A held fetch never finishes here: the test goes on once it is out.
    try await world.waitUntil("initialize to return", timeout: 10) {
        if world.network.isHolding("getCampaigns"),
           world.network.logSnapshot(from: 0).filter({ $0.endpoint == "getCampaigns" }).count > before
        {
            return true
        }
        return finished && sdk.sdkState != .initializing
    }
}

/// Before `launchApp`: a value a previous run left in storage.
@MainActor private func seedStorage(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let key = args["key"] as? String ?? ""
    guard key == "app_opens" || key == "device_id" else {
        throw YamlTestFailure(
            "seedStorage: unknown key \"\(key)\"",
            expected: "app_opens, device_id",
            line: world.step.line)
    }
    world.seeds[key] = args["value"] ?? NSNull()
}

/// What a CEP does when its campaign fires.
@MainActor private func triggerCep(_ world: YamlWorld, _ args: [String: Any]) async throws {
    try fireTrigger(world, args)
    if SDKInstance.shared.floaterOrchestrator.awaitingMedia {
        let deadline = Date().addingTimeInterval(0.3)
        while SDKInstance.shared.floaterOrchestrator.awaitingMedia && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Triggers the campaign and immediately cancels it before it displays, with
/// no settle between, as a CEP cancel landing while the window is still
/// loading its media does. The delivery drops as cancelled.
@MainActor private func triggerAndCancel(_ world: YamlWorld, _ args: [String: Any]) async throws {
    try fireTrigger(world, args)
    let key = args["campaignKey"] as? String ?? ""
    guard let delivery = world.cep.deliveries.last(where: { $0.trigger.campaignKey == key }) else {
        throw YamlTestFailure(
            "nothing delivered for \"\(key)\"",
            expected: "a triggerCep for \"\(key)\" before this step",
            line: world.step.line)
    }
    delivery.presentation.cancel()
}

/// Delivers several CEP triggers in one step, with no settle between them:
/// the later ones route while the earlier ones have not displayed yet, as a
/// CEP firing a burst. Queued when the SDK is not ready yet, like triggerCep.
@MainActor private func triggerCeps(_ world: YamlWorld, _ args: [String: Any]) async throws {
    guard let raw = args["triggers"] as? [Any], !raw.isEmpty else {
        throw YamlTestFailure(
            "triggerCeps: needs a non-empty triggers list",
            expected: "triggers: [{campaignKey: a}, {campaignKey: b}]",
            line: world.step.line)
    }
    for item in raw {
        guard let trigger = item as? [String: Any] else {
            throw YamlTestFailure(
                "triggerCeps: each trigger is a triggerCep map",
                expected: "{campaignKey: a}",
                line: world.step.line)
        }
        try fireTrigger(world, trigger)
    }
}

@MainActor private func fireTrigger(_ world: YamlWorld, _ args: [String: Any]) throws {
    let key = args["campaignKey"] as? String ?? ""
    let cepId: String = {
        if let id = args["cepCampaignId"] as? String { return id }
        return "cep-\(key)"
    }()
    func strings(_ value: Any?) -> [String: String] {
        guard let map = value as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: map.map { ($0.key, "\($0.value)") })
    }
    let variables: [String: String]? = {
        if let direct = args["variables"] as? [String: String] {
            return direct.isEmpty ? nil : direct
        }
        let mapped = strings(args["variables"])
        return mapped.isEmpty ? nil : mapped
    }()
    world.cep.fire(CEPTriggerPayload(
        cepCampaignId: cepId,
        campaignKey: key,
        cepMetadata: strings(args["cepMetadata"]),
        variables: variables))
}

/// The dashboard's "Test on device": routes a `campaign_test` payload through
/// the live-test entry, as the live stream would. The campaign renders
/// directly from `fixture`, never from the bundle.
@MainActor private func liveTest(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let noCampaign = (args["noCampaign"] as? Bool) ?? false
    let unparsable = (args["unparsable"] as? Bool) ?? false
    if noCampaign && unparsable {
        throw YamlTestFailure(
            "liveTest: noCampaign and unparsable exclude each other",
            line: world.step.line)
    }
    var campaign: [String: Any]?
    if !noCampaign {
        guard let fixture = args["fixture"] else {
            throw YamlTestFailure(
                "liveTest: needs a fixture, or noCampaign: true",
                expected: "a .json path or inline campaign JSON",
                line: world.step.line)
        }
        guard var loaded = try world.json(fixture) as? [String: Any] else {
            throw YamlTestFailure(
                "liveTest: fixture is not one campaign object",
                expected: "a JSON object in \(fixture)",
                line: world.step.line)
        }
        if unparsable { loaded["templateConfig"] = "not-an-object" }
        campaign = loaded
    }
    let variables: [String: Any] = {
        guard let raw = args["variables"] as? [String: Any] else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.map { ($0.key, $0.value) })
    }()
    let sdk = try world.sdk
    // The reporter only posts once configured, which a held campaign fetch
    // never reaches; the harness configures it the same way.
    sdk.liveTestService.ackReporter.configure(config: DigiaConfig(apiKey: "test-api-key"))
    let invocationId = (args["invocationId"] as? String) ?? "inv-1"
    sdk.handleLiveTestCampaign(LiveTestInvocation(
        testInvocationId: invocationId,
        campaignId: campaign?["campaignKey"] as? String ?? "live-test",
        campaign: campaign,
        variables: variables))
    // ACKs ride Tasks that can land out of order; the invocation is over only
    // when its terminal ACK (anything but `received`) is on the wire — except
    // for a valid survey, whose start delay (150ms+) waits on the fake clock
    // (`advanceTime` in the next step), so waiting for `received` lets the
    // test advance time and display the survey.
    let isSurvey = !noCampaign && !unparsable
        && ((campaign?["templateConfig"] as? [String: Any])?["templateType"] as? String == "survey"
            || (campaign?["type"] as? String)?.lowercased() == "survey")
    let deadline = Date().addingTimeInterval(10)
    while true {
        await world.settle()
        let done = world.network.logSnapshot(from: 0).contains { record in
            guard record.endpoint == "liveTestAck",
                  let body = record.body as? [String: Any],
                  (body["testInvocationId"] as? String) == invocationId
            else { return false }
            let status = body["status"] as? String
            return isSurvey ? (status != nil) : (status != "received")
        }
        if done { return }
        if Date() > deadline {
            throw YamlTestFailure(
                "liveTest: no terminal ACK for \"\(invocationId)\"",
                expected: "a shown or failed ACK on liveTestAck",
                line: world.step.line)
        }
    }
}

/// The CEP ends its in-app for the campaign: cancel the last delivery of the
/// key, as CleverTap CustomTemplateClose or WebEngage native dismiss do.
@MainActor private func cancelCep(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let key = args["campaignKey"] as? String ?? ""
    guard let delivery = world.cep.deliveries.last(where: { $0.trigger.campaignKey == key }) else {
        throw YamlTestFailure(
            "nothing delivered for \"\(key)\"",
            expected: "a triggerCep for \"\(key)\" before this step",
            actual: "none",
            line: world.step.line)
    }
    delivery.presentation.cancel()
}
