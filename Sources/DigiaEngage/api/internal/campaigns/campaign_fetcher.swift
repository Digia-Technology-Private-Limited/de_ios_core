import Foundation

private enum DigiaCampaignEndpoints {
    static let production = "https://api.digia.tech/api/v1"
    static let sandbox = "https://zaiden-phonematic-unseemly.ngrok-free.dev/api/v1"
}

struct CampaignFetcher {
    let config: DigiaConfig

    func fetch() async throws -> [CampaignModel] {
        let url = try campaignURL()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers()
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw DigiaConfigError.network("getCampaigns failed: HTTP \(http.statusCode)")
        }

        let json = try JSONSerialization.jsonObject(with: data)
        let campaigns = try extractCampaignArray(json)
        return campaigns.compactMap(CampaignModel.from)
    }

    private func campaignURL() throws -> URL {
        let baseURL = normalizedCampaignBaseURL()
        guard let url = URL(string: baseURL + "/engage/sdk/getCampaigns") else {
            throw DigiaConfigError.network("Invalid campaign URL")
        }
        return url
    }

    private func normalizedCampaignBaseURL() -> String {
        let rawBase =
            config.baseUrl
            ?? config.developerConfig?.baseURL
            ?? (config.environment == .sandbox
                ? DigiaCampaignEndpoints.sandbox : DigiaCampaignEndpoints.production)
        let trimmed = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.hasSuffix("/api/v1") ? trimmed : trimmed + "/api/v1"
    }

    private func headers() -> [String: String] {
        let environment = config.environment == .production ? "production" : "sandbox"
        var headers = config.networkConfiguration?.defaultHeaders ?? [:]
        headers["Content-Type"] = "application/json"
        // headers["X-Api-Key"] = config.apiKey
        headers["x-digia-project-id"] = config.apiKey
        headers["x-digia-platform"] = "ios"
        headers["x-digia-environment"] = environment
        return headers
    }

    private func extractCampaignArray(_ json: Any) throws -> [[String: Any]] {
        if let array = json as? [[String: Any]] {
            return array
        }

        if let object = json as? [String: Any],
            let data = object["data"] as? [String: Any],
            let response = data["response"] as? [[String: Any]]
        {
            return response
        }

        if let object = json as? [String: Any],
            let response = object["response"] as? [[String: Any]]
        {
            return response
        }

        throw DigiaConfigError.decodeFailure("getCampaigns response missing data.response")
    }
}

struct CampaignModel: Equatable {
    let id: String
    let campaignKey: String
    let campaignType: String
    let surveyConfig: [String: JSONValue]?

    static func from(_ json: [String: Any]) -> CampaignModel? {
        guard let id = firstNonEmptyString(json["id"]),
            let campaignKey = firstNonEmptyString(json["campaignKey"]),
            let campaignType = firstNonEmptyString(json["campaignType"])
        else {
            return nil
        }

        return CampaignModel(
            id: id,
            campaignKey: campaignKey,
            campaignType: campaignType,
            surveyConfig: surveyConfigJSON(from: json)
        )
    }

    func makePayload() -> InAppPayload? {
        switch campaignType {
        case "survey":
            guard let surveyConfig else { return nil }
            return InAppPayload(
                id: campaignKey,
                content: InAppPayloadContent(
                    type: "survey",
                    command: "SHOW_SURVEY",
                    args: [
                        "campaign_id": .string(id),
                        "campaign_key": .string(campaignKey),
                        "survey_config": .object(surveyConfig),
                    ]
                ),
                cepContext: [
                    "campaignId": id,
                    "campaignKey": campaignKey,
                ]
            )
        default:
            return nil
        }
    }

    private static func surveyConfigJSON(from json: [String: Any]) -> [String: JSONValue]? {
        if let survey = json["surveyConfig"] as? [String: Any] {
            return jsonObject(survey)
        }

        if let template = json["templateConfig"] as? [String: Any],
            firstNonEmptyString(template["templateType"]) == "survey"
        {
            return jsonObject(template)
        }

        return nil
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
}

final class CampaignStore {
    private var campaigns: [CampaignModel] = []

    func populate(_ campaigns: [CampaignModel]) {
        self.campaigns = campaigns
    }

    func find(_ identifier: String) -> CampaignModel? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return campaigns.first { campaign in
            campaign.id == trimmed || campaign.campaignKey == trimmed
        }
    }

    func findByKey(_ campaignKey: String) -> CampaignModel? {
        let trimmed = campaignKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return campaigns.first { $0.campaignKey == trimmed }
    }

    func findById(_ campaignId: String) -> CampaignModel? {
        let trimmed = campaignId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return campaigns.first { $0.id == trimmed }
    }

    func clear() {
        campaigns.removeAll()
    }
}

private func jsonObject(_ dictionary: [String: Any]) -> [String: JSONValue]? {
    var result: [String: JSONValue] = [:]
    for (key, value) in dictionary {
        guard let jsonValue = jsonValue(value) else { return nil }
        result[key] = jsonValue
    }
    return result
}

private func jsonValue(_ value: Any) -> JSONValue? {
    switch value {
    case let string as String:
        return .string(string)
    case let bool as Bool:
        return .bool(bool)
    case let int as Int:
        return .int(int)
    case let double as Double:
        return .double(double)
    case let number as NSNumber:
        return .double(number.doubleValue)
    case let array as [Any]:
        var values: [JSONValue] = []
        for item in array {
            guard let mapped = jsonValue(item) else { return nil }
            values.append(mapped)
        }
        return .array(values)
    case let object as [String: Any]:
        guard let mapped = jsonObject(object) else { return nil }
        return .object(mapped)
    case is NSNull:
        return .null
    default:
        return nil
    }
}
