import Foundation
@testable import DigiaEngage

/// Boots the SDK and fires the CEP. Mirrors `handlers/core.dart`.
let yamlCoreHandlers: [String: YamlHandler] = [
    "launchApp": launchApp,
    "triggerCep": triggerCep,
]

/// Boots the SDK serving what `mockApi: getCampaigns` set, under a plain
/// host screen. A second launch without `clearState` is a relaunch over the
/// same storage.
@MainActor private func launchApp(_ world: YamlWorld, _ args: [String: Any]) async throws {
    let host = args["host"] as? String ?? "plain"
    if host != "plain" && host != "phone" {
        throw YamlTestFailure(
            "unknown host \"\(host)\"",
            expected: "plain or phone",
            line: world.step.line)
    }
    try await world.bootForTest(
        clearState: args["clearState"] as? Bool ?? false,
        mountPhone: host == "phone")
}

/// What a CEP does when its campaign fires.
@MainActor private func triggerCep(_ world: YamlWorld, _ args: [String: Any]) async throws {
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
